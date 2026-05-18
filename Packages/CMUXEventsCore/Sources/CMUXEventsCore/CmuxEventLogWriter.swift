import Foundation
import os

nonisolated private let cmuxEventLogLogger = Logger(subsystem: "com.cmuxterm.app", category: "event-log")

// Sendable safety: pending state is protected by `lock`; file IO runs from `flushTask`.
final class CmuxEventLogWriter: @unchecked Sendable {
    static let defaultMaxPendingLines = 1_024

    private let eventLogURL: URL
    private let maxEventLogBytes: UInt64
    private let maxPendingLines: Int
    private let lock = NSLock()
    private var pendingLines: [String] = []
    private var flushTask: Task<Void, Never>?
    private var droppedLineCount = 0
#if DEBUG
    private var flushSuspendedForTesting = false
#endif

    init(eventLogURL: URL, maxEventLogBytes: UInt64, maxPendingLines: Int) {
        self.eventLogURL = eventLogURL
        self.maxEventLogBytes = max(1, maxEventLogBytes)
        self.maxPendingLines = max(1, maxPendingLines)
    }

    func enqueue(_ line: String) {
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
        scheduleFlushIfNeededLocked()
        lock.unlock()
    }

#if DEBUG
    func flushForTesting() async {
        while let task = scheduleFlushIfNeeded() {
            await task.value
        }
    }

    func setFlushSuspendedForTesting(_ suspended: Bool) {
        lock.lock()
        flushSuspendedForTesting = suspended
        lock.unlock()
        if !suspended {
            _ = scheduleFlushIfNeeded()
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
        droppedLineCount = 0
        flushSuspendedForTesting = false
        lock.unlock()
    }
#endif

    @discardableResult
    private func scheduleFlushIfNeeded() -> Task<Void, Never>? {
        lock.lock()
        let task = scheduleFlushIfNeededLocked()
        lock.unlock()
        return task
    }

    @discardableResult
    private func scheduleFlushIfNeededLocked() -> Task<Void, Never>? {
#if DEBUG
        guard !flushSuspendedForTesting else {
            return flushTask
        }
#endif
        if let flushTask {
            return flushTask
        }
        guard !pendingLines.isEmpty else {
            return nil
        }
        // `publish` is intentionally synchronous; the detached utility task prevents
        // file IO from inheriting the caller actor while keeping one drain active.
        let task = Task.detached(priority: .utility) { [self] in
            await flushPendingLines()
        }
        flushTask = task
        return task
    }

    private func flushPendingLines() async {
        while true {
            let lines: [String]
            let droppedCount: Int
            lock.lock()
            if pendingLines.isEmpty {
                flushTask = nil
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
        do {
            try FileManager.default.createDirectory(
                at: eventLogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: eventLogURL.path) {
                _ = fileManager.createFile(atPath: eventLogURL.path, contents: nil)
            }
            var handle = try FileHandle(forWritingTo: eventLogURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            var currentSize = Self.fileSize(at: eventLogURL, fileManager: fileManager)
            for line in lines {
                let data = Data((line + "\n").utf8)
                if currentSize + UInt64(data.count) > maxEventLogBytes {
                    try handle.close()
                    try rotate(fileManager: fileManager)
                    handle = try FileHandle(forWritingTo: eventLogURL)
                    currentSize = 0
                }
                try handle.write(contentsOf: data)
                currentSize += UInt64(data.count)
            }
        } catch {
            cmuxEventLogLogger.error("Failed to append cmux event log: \(String(describing: error), privacy: .private)")
        }
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
