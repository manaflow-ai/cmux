import Darwin
import Foundation
import os

nonisolated enum StartupBreadcrumbLog {
    struct Record: Equatable, Sendable {
        let timestamp: Date
        let event: String
        let fields: [String: String]
    }

    struct DeferredBatch: Equatable, Sendable {
        let records: [Record]
        let droppedRecordCount: Int
    }

    struct DeferredBuffer: Sendable {
        private let capacity: Int
        private var records: [Record] = []
        private var droppedRecordCount = 0
        private var isDrainScheduled = false

        init(capacity: Int) {
            self.capacity = max(1, capacity)
            records.reserveCapacity(self.capacity)
        }

        /// Returns true only when the caller must schedule the single drain task.
        mutating func enqueue(_ record: Record) -> Bool {
            if records.count < capacity {
                records.append(record)
            } else if droppedRecordCount < Int.max {
                droppedRecordCount += 1
            }

            guard !isDrainScheduled else { return false }
            isDrainScheduled = true
            return true
        }

        mutating func takeBatch() -> DeferredBatch? {
            guard !records.isEmpty || droppedRecordCount > 0 else {
                isDrainScheduled = false
                return nil
            }
            let batch = DeferredBatch(records: records, droppedRecordCount: droppedRecordCount)
            records.removeAll(keepingCapacity: true)
            droppedRecordCount = 0
            return batch
        }
    }

    private actor DeferredWriter {
        private var buffer = DeferredBuffer(capacity: StartupBreadcrumbLog.maxDeferredRecordCount)
        private var drainTask: Task<Void, Never>?

        func enqueue(_ record: Record) {
            guard buffer.enqueue(record) else { return }
            drainTask = Task { [weak self] in
                // Yield once so a synchronous restore burst reaches the actor before the first write.
                await Task.yield()
                await self?.drain()
            }
        }

        private func drain() async {
            while let batch = buffer.takeBatch() {
                let records = StartupBreadcrumbLog.records(in: batch)
                await Task.detached(priority: .utility) {
                    StartupBreadcrumbLog.write(records)
                }.value
            }
            drainTask = nil
        }
    }

    private static let maxFieldLength = 240
    private static let maxFieldKeyLength = 80
    private static let maxFieldCount = 32
    private static let maxDeferredRecordCount = 512
    private static let maxLogByteCount = 4 * 1024 * 1024
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "StartupBreadcrumbLog")
    private static let deferredContinuation: AsyncStream<Record>.Continuation = {
        let writer = DeferredWriter()
        let (stream, continuation) = AsyncStream<Record>.makeStream(
            bufferingPolicy: .bufferingNewest(maxDeferredRecordCount)
        )
        // Process-lifetime consumer: the bounded stream is the synchronous,
        // lock-free handoff from restore code to the actor-owned batch.
        Task.detached(priority: .utility) {
            for await record in stream {
                await writer.enqueue(record)
            }
        }
        return continuation
    }()
    private static let reservedFieldKeys: Set<String> = [
        "timestamp",
        "event",
        "pid",
        "bundleIdentifier",
        "appVersion",
        "build"
    ]

    /// Writes a low-cardinality edge synchronously so it survives an immediate launch abort.
    static func append(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }
        write([record(event: event, fields: fields)])
    }

    /// Buffers high-cardinality diagnostics and writes them off the caller's actor in bounded batches.
    static func appendBatched(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }
        let record = record(event: event, fields: fields)
        if case .dropped = deferredContinuation.yield(record) {
            logger.warning("cmux startup breadcrumb input buffer dropped an old record")
        }
    }

    private static func record(event: String, fields: [String: String]) -> Record {
        var boundedFields: [String: String] = [:]
        boundedFields.reserveCapacity(min(fields.count, maxFieldCount))
        for (key, value) in fields.sorted(by: { $0.key < $1.key }).prefix(maxFieldCount) {
            let boundedKey = sanitized(key, maxLength: maxFieldKeyLength)
            boundedFields[boundedKey] = sanitized(value)
        }
        return Record(
            timestamp: Date(),
            event: sanitized(event),
            fields: boundedFields
        )
    }

    private static func records(in batch: DeferredBatch) -> [Record] {
        guard batch.droppedRecordCount > 0 else { return batch.records }
        var records = batch.records
        records.append(
            record(
                event: "startup.breadcrumb.batch.dropped",
                fields: ["count": String(batch.droppedRecordCount)]
            )
        )
        return records
    }

    private static func write(_ records: [Record]) {
        guard !records.isEmpty else { return }
        do {
            let data = try encodedData(for: records)
            try append(data, to: logURL)
        } catch {
            logger.fault("cmux startup breadcrumb failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func encodedData(for records: [Record]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        let processInfo = ProcessInfo.processInfo
        let bundle = Bundle.main
        let sharedFields: [String: Any] = [
            "pid": processInfo.processIdentifier,
            "bundleIdentifier": bundle.bundleIdentifier ?? "unknown",
            "appVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]
        var output = Data()

        for record in records {
            var payload = sharedFields
            payload["timestamp"] = formatter.string(from: record.timestamp)
            payload["event"] = record.event
            for (key, value) in record.fields {
                let payloadKey = reservedFieldKeys.contains(key) ? "custom_\(key)" : key
                payload[payloadKey] = value
            }
            output.append(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            output.append(0x0A)
        }
        return output
    }

    private static func append(_ data: Data, to url: URL) throws {
        let boundedAppend = boundedJSONLTail(data, maximumByteCount: maxLogByteCount)
        guard !boundedAppend.isEmpty else { return }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            let errorNumber = errno
            if errorNumber == EWOULDBLOCK || errorNumber == EAGAIN {
                return
            }
            let code = POSIXErrorCode(rawValue: errorNumber) ?? .EIO
            throw POSIXError(code)
        }
        defer { flock(handle.fileDescriptor, LOCK_UN) }

        let currentSize = try handle.seekToEnd()
        if currentSize <= UInt64(maxLogByteCount - boundedAppend.count) {
            try handle.write(contentsOf: boundedAppend)
            return
        }

        let existingByteBudget = maxLogByteCount - boundedAppend.count
        let requestedReadCount = existingByteBudget + (existingByteBudget > 0 ? 1 : 0)
        let readCount = Int(min(currentSize, UInt64(requestedReadCount)))
        var combined = Data()
        if readCount > 0 {
            try handle.seek(toOffset: currentSize - UInt64(readCount))
            combined = try handle.read(upToCount: readCount) ?? Data()
        }
        let replacement = boundedJSONLTail(
            existingTail: combined,
            appending: boundedAppend,
            maximumByteCount: maxLogByteCount
        )

        guard ftruncate(handle.fileDescriptor, 0) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(code)
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: replacement)
    }

    static func boundedJSONLTail(
        existingTail: Data,
        appending data: Data,
        maximumByteCount: Int
    ) -> Data {
        let boundedAppend = boundedJSONLTail(data, maximumByteCount: maximumByteCount)
        guard !boundedAppend.isEmpty else { return Data() }
        var combined = existingTail
        combined.append(boundedAppend)
        let boundedCombined = boundedJSONLTail(combined, maximumByteCount: maximumByteCount)
        return boundedCombined.isEmpty ? boundedAppend : boundedCombined
    }

    static func boundedJSONLTail(_ data: Data, maximumByteCount: Int) -> Data {
        guard maximumByteCount > 0 else { return Data() }
        guard data.count > maximumByteCount else { return data }

        let startIndex = data.index(data.endIndex, offsetBy: -maximumByteCount)
        let precedingIndex = data.index(before: startIndex)
        if data[precedingIndex] == 0x0A {
            return Data(data[startIndex...])
        }
        guard let newlineIndex = data[startIndex...].firstIndex(of: 0x0A) else {
            return Data()
        }
        return Data(data[data.index(after: newlineIndex)...])
    }

    private static var isEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["CMUX_DISABLE_STARTUP_BREADCRUMBS"] == "1" {
            return false
        }
        if environment["CMUX_STARTUP_BREADCRUMBS"] == "1" {
            return true
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        return bundleIdentifier == "com.cmuxterm.app.nightly"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.nightly.")
            || bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
    }

    private static var logURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/cmux", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-logs", isDirectory: true)
        let sanitizedBundleIdentifier = logFileComponent(Bundle.main.bundleIdentifier ?? "unknown")
        return logsDirectory.appendingPathComponent("startup-\(sanitizedBundleIdentifier).log")
    }

    private static func logFileComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return sanitized(value, maxLength: 160).unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    private static func sanitized(_ value: String, maxLength: Int = maxFieldLength) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if flattened.count <= maxLength {
            return flattened
        }
        return String(flattened.prefix(maxLength)) + "...<truncated>"
    }
}
