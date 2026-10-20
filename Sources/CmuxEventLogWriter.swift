import Foundation
import os

nonisolated private let cmuxEventLogLogger = Logger(subsystem: "com.cmuxterm.app", category: "event-log")

// Sendable safety: pending state is protected by `lock`; file IO and
// `openLogHandle` are confined to `queue`.
final class CmuxEventLogWriter: @unchecked Sendable {
    static let defaultMaxPendingLines = 1_024

    private static let queue = DispatchQueue(label: "com.cmuxterm.event-log", qos: .utility)

    private let eventLogURL: URL
    private let maxEventLogBytes: UInt64
    private let maxPendingLines: Int
    private let writeData: @Sendable (FileHandle, Data) throws -> Void
    private let lock = NSLock()
    private var pendingLines: [String] = []
    private var flushScheduled = false
    private var droppedLineCount = 0
    /// The append-only log descriptor kept open across flushes.
    private var openLogHandle: FileHandle?
#if DEBUG
    private var flushSuspendedForTesting = false
#endif

    init(
        eventLogURL: URL,
        maxEventLogBytes: UInt64,
        maxPendingLines: Int,
        writeData: @escaping @Sendable (FileHandle, Data) throws -> Void = { handle, data in
            try handle.write(contentsOf: data)
        }
    ) {
        self.eventLogURL = eventLogURL
        self.maxEventLogBytes = max(1, maxEventLogBytes)
        self.maxPendingLines = max(1, maxPendingLines)
        self.writeData = writeData
    }

    func enqueue(_ line: String) {
        var shouldSchedule = false
        lock.lock()
        if pendingLines.count >= maxPendingLines {
            let removedCount = pendingLines.count - maxPendingLines + 1
            pendingLines.removeFirst(removedCount)
            droppedLineCount += removedCount
        }
        pendingLines.append(line)
#if DEBUG
        if flushSuspendedForTesting {
            lock.unlock()
            return
        }
#endif
        if !flushScheduled {
            flushScheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        if shouldSchedule {
            Self.queue.async { [self] in flushPendingLines() }
        }
    }

#if DEBUG
    func flushForTesting() {
        scheduleFlushIfNeeded()
        Self.queue.sync {}
    }

    func setFlushSuspendedForTesting(_ suspended: Bool) {
        lock.lock()
        flushSuspendedForTesting = suspended
        lock.unlock()
        if !suspended {
            scheduleFlushIfNeeded()
        }
    }

    func backlogSnapshotForTesting() -> (pending: Int, dropped: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (pendingLines.count, droppedLineCount)
    }

    func resetForTesting() {
        lock.lock()
        pendingLines.removeAll()
        flushScheduled = false
        droppedLineCount = 0
        flushSuspendedForTesting = false
        lock.unlock()
    }
#endif

    private func scheduleFlushIfNeeded() {
        var shouldSchedule = false
        lock.lock()
#if DEBUG
        guard !flushSuspendedForTesting else {
            lock.unlock()
            return
        }
#endif
        if !pendingLines.isEmpty, !flushScheduled {
            flushScheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        if shouldSchedule {
            Self.queue.async { [self] in flushPendingLines() }
        }
    }

    private func flushPendingLines() {
        while true {
            let lines: [String]
            let droppedCount: Int
            lock.lock()
            if pendingLines.isEmpty {
                flushScheduled = false
                droppedCount = droppedLineCount
                droppedLineCount = 0
                lock.unlock()
                if droppedCount > 0 {
                    cmuxEventLogLogger.warning("Dropped \(droppedCount, privacy: .public) cmux event log line(s) under disk backpressure")
                }
                return
            }
            lines = pendingLines
            pendingLines.removeAll(keepingCapacity: true)
            lock.unlock()
            append(lines)
        }
    }

    private func append(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let fileManager = FileManager.default
        do {
            var (handle, currentSize) = try logHandleForAppending(fileManager: fileManager)
            // One file segment at a time bounds the extra buffer to the rotation limit,
            // except for an indivisible oversized record (the existing write-whole policy).
            var batchData = Data()

            func writeBatch() throws {
                guard !batchData.isEmpty else { return }
                try writeData(handle, batchData)
                batchData.removeAll(keepingCapacity: true)
            }

            for line in lines {
                let lineBytes = UInt64(line.utf8.count) + 1
                if currentSize + lineBytes > maxEventLogBytes {
                    try writeBatch()
                    closeOpenLog()
                    try rotate(fileManager: fileManager)
                    (handle, currentSize) = try logHandleForAppending(fileManager: fileManager)
                }
                batchData.append(contentsOf: line.utf8)
                batchData.append(0x0a)
                currentSize += lineBytes
            }
            try writeBatch()
        } catch {
            closeOpenLog()
            cmuxEventLogLogger.error("Failed to append cmux event log: \(String(describing: error), privacy: .private)")
        }
    }

    /// Returns an append-only handle for the log and the log's current size.
    ///
    /// Events are flushed one burst at a time, often a single line. Reopening,
    /// creating the directory, and stat'ing the file on every flush dominated the
    /// event-log queue, so the handle stays open. Other cmux processes share this
    /// log and may rotate, delete, or append to it:
    /// - The open handle is reused only while the path still names the same file
    ///   (device and inode match).
    /// - The descriptor is opened with `O_APPEND`, so every write lands at the
    ///   current end of file even when another process appended since our last
    ///   write. A seek-then-write handle could overwrite those lines.
    /// - The size used for rotation comes from `fstat` on the open descriptor.
    private func logHandleForAppending(fileManager: FileManager) throws -> (FileHandle, UInt64) {
        let path = eventLogURL.path
        var pathStatus = stat()
        let pathExists = stat(path, &pathStatus) == 0
        if let handle = openLogHandle {
            var handleStatus = stat()
            if pathExists,
               fstat(handle.fileDescriptor, &handleStatus) == 0,
               handleStatus.st_dev == pathStatus.st_dev,
               handleStatus.st_ino == pathStatus.st_ino {
                return (handle, UInt64(max(0, handleStatus.st_size)))
            }
            closeOpenLog()
        }

        // Directory creation runs only when the open reports a missing parent.
        var descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        if descriptor < 0, errno == ENOENT {
            try fileManager.createDirectory(
                at: eventLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var handleStatus = stat()
        guard fstat(descriptor, &handleStatus) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? handle.close()
            throw POSIXError(code)
        }
        openLogHandle = handle
        return (handle, UInt64(max(0, handleStatus.st_size)))
    }

    private func closeOpenLog() {
        guard let handle = openLogHandle else { return }
        try? handle.close()
        openLogHandle = nil
    }

    private func rotate(fileManager: FileManager) throws {
        let currentSize = Self.fileSize(at: eventLogURL, fileManager: fileManager)
        let rotatedURL = eventLogURL.appendingPathExtension("1")
        if Self.fileSize(at: rotatedURL, fileManager: fileManager) > maxEventLogBytes {
            try fileManager.removeItem(at: rotatedURL)
        }
        if currentSize > maxEventLogBytes {
            try fileManager.removeItem(at: eventLogURL)
            _ = fileManager.createFile(atPath: eventLogURL.path, contents: nil)
            return
        }

        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }
        if fileManager.fileExists(atPath: eventLogURL.path) {
            try fileManager.moveItem(at: eventLogURL, to: rotatedURL)
        }
        _ = fileManager.createFile(atPath: eventLogURL.path, contents: nil)
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> UInt64 {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return 0
        }
        return size.uint64Value
    }
}
