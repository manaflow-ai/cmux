public import Foundation

/// Append-only ring buffer of recent debug log lines, owned by an `actor` so
/// concurrent writers from Ghostty IO/render threads serialize without a lock.
///
/// This replaces the previous `Synchronization.Mutex`-backed store. Mutation
/// happens through ``append(_:)`` (each line is timestamped with seconds since
/// the sink was created), and observers can subscribe to ``lines()`` for a live
/// `AsyncStream` of every appended line or pull the whole buffer with
/// ``snapshot()``.
public actor MobileDebugLogSink {
    private var buffer: [String] = []
    private let capacity: Int
    private let startedAt: Date
    private let now: @Sendable () -> Date
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private let fileURL: URL?
    private let fileHeader: String?
    private let maxFileBytes: Int
    private var fileHandle: FileHandle?
    private var fileLoggingEnabled: Bool
    private var fileBytesWritten: Int
    private var crashCaptureInstalled: Bool

    /// Create a sink.
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of retained lines. Oldest lines are dropped
    ///     once the buffer grows past this. Defaults to `4000`.
    ///   - now: Clock used to timestamp lines and anchor the elapsed offset.
    ///     Injected so tests can pin time; defaults to `Date.init`.
    ///   - fileURL: Optional on-disk log location. When non-`nil`, an existing
    ///     file is rotated to `<path>.1`, a fresh file is opened, and each
    ///     appended line is written immediately. File failures disable only file
    ///     logging for this sink.
    ///   - fileHeader: Optional first line written to a newly opened log file.
    ///   - maxFileBytes: Maximum approximate size of the active log generation.
    ///     When appending a line would exceed this limit, the current file is
    ///     rotated to `<path>.1`, a fresh file is opened, and the line is written
    ///     to the new generation. Defaults to `5_000_000`.
    ///   - installCrashCapture: When `true`, DEBUG builds install crash handlers
    ///     against the opened file descriptor. Defaults to `false` so tests and
    ///     custom sinks do not mutate process-wide handler state.
    public init(
        capacity: Int = 4000,
        now: @escaping @Sendable () -> Date = { Date() },
        fileURL: URL? = nil,
        fileHeader: String? = nil,
        maxFileBytes: Int = 5_000_000,
        installCrashCapture: Bool = false
    ) {
        self.capacity = capacity
        self.now = now
        self.startedAt = now()
        self.fileURL = fileURL
        self.fileHeader = fileHeader
        self.maxFileBytes = maxFileBytes
        self.fileBytesWritten = 0
        self.crashCaptureInstalled = false
        if let fileURL, let openedLogFile = Self.openLogFile(at: fileURL, header: fileHeader) {
            self.fileHandle = openedLogFile.fileHandle
            self.fileLoggingEnabled = true
            self.fileBytesWritten = openedLogFile.byteCount
            #if DEBUG
            if installCrashCapture {
                MobileDebugLogCrashCapture.install(
                    logFileDescriptor: openedLogFile.fileHandle.fileDescriptor
                )
                self.crashCaptureInstalled = true
            }
            #endif
        } else {
            self.fileHandle = nil
            self.fileLoggingEnabled = false
        }
    }

    deinit {
        if let fileHandle {
            try? fileHandle.close()
        }
    }

    /// Append one timestamped line (seconds elapsed since the sink was created).
    ///
    /// The line is broadcast to every active ``lines()`` subscriber and stored
    /// in the ring buffer, evicting the oldest entries past the capacity. When
    /// file logging is configured, the same line is also appended to disk before
    /// this method returns.
    public func append(_ message: String) {
        let elapsed = String(format: "%9.3f", now().timeIntervalSince(startedAt))
        let line = "[\(elapsed)] \(message)"
        buffer.append(line)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for continuation in continuations.values {
            continuation.yield(line)
        }
        appendToFile(line)
    }

    /// The full buffer as newline-joined text, newest last.
    public func snapshot() -> String {
        buffer.joined(separator: "\n")
    }

    /// The current buffered lines and their count, newest last.
    ///
    /// - Returns: A tuple of the line count and the newline-joined body. Useful
    ///   when a caller needs both without two round-trips to the actor.
    public func snapshotWithCount() -> (count: Int, body: String) {
        (buffer.count, buffer.joined(separator: "\n"))
    }

    /// Remove every buffered line, keeping the allocated capacity.
    ///
    /// This clears only the in-memory buffer. A configured file log is the
    /// durable record for crash diagnosis and is not truncated.
    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// A live stream of every line appended after subscription.
    ///
    /// The stream finishes when the sink is deinitialized. Cancelling the
    /// consuming task detaches its continuation.
    public func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    private static func openLogFile(
        at fileURL: URL,
        header: String?
    ) -> (fileHandle: FileHandle, byteCount: Int)? {
        let fileManager = FileManager.default
        do {
            try rotateExistingLog(at: fileURL, fileManager: fileManager)
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                return nil
            }
            let fileHandle = try FileHandle(forWritingTo: fileURL)
            var byteCount = 0
            if let header {
                let headerData = Data("\(header)\n".utf8)
                try fileHandle.write(contentsOf: headerData)
                byteCount = headerData.count
            }
            return (fileHandle: fileHandle, byteCount: byteCount)
        } catch {
            return nil
        }
    }

    private static func rotateExistingLog(at fileURL: URL, fileManager: FileManager) throws {
        let rotatedURL = URL(fileURLWithPath: fileURL.path + ".1")
        if fileManager.fileExists(atPath: fileURL.path) {
            if fileManager.fileExists(atPath: rotatedURL.path) {
                try fileManager.removeItem(at: rotatedURL)
            }
            try fileManager.moveItem(at: fileURL, to: rotatedURL)
        }
    }

    private func appendToFile(_ line: String) {
        guard fileLoggingEnabled else {
            return
        }
        let lineData = Data("\(line)\n".utf8)
        if fileBytesWritten + lineData.count > maxFileBytes, !rotateLogFile() {
            disableFileLogging()
            return
        }
        guard let fileHandle else {
            disableFileLogging()
            return
        }
        do {
            try fileHandle.write(contentsOf: lineData)
            fileBytesWritten += lineData.count
        } catch {
            disableFileLogging()
        }
    }

    private func rotateLogFile() -> Bool {
        guard let fileURL else {
            return false
        }
        closeFileHandle()
        guard let openedLogFile = Self.openLogFile(at: fileURL, header: fileHeader) else {
            return false
        }
        fileHandle = openedLogFile.fileHandle
        fileBytesWritten = openedLogFile.byteCount
        fileLoggingEnabled = true
        #if DEBUG
        if crashCaptureInstalled {
            // A crash exactly during rotation may write into the just-rotated
            // generation via the previous dup'd fd; that file still survives.
            MobileDebugLogCrashCapture.updateLogFileDescriptor(
                openedLogFile.fileHandle.fileDescriptor
            )
        }
        #endif
        return true
    }

    private func disableFileLogging() {
        fileLoggingEnabled = false
        closeFileHandle()
    }

    private func closeFileHandle() {
        guard let fileHandle else {
            return
        }
        try? fileHandle.close()
        self.fileHandle = nil
    }
}
