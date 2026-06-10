import Foundation
import QuartzCore

/// Sink that performs the durable write for a single formatted log line.
/// All `write(_:)` calls are serialized by `BackgroundLogWriter` onto its
/// private queue, so implementations don't need their own locking.
protocol BackgroundLogSink: AnyObject {
    func write(_ line: String)
}

/// File-backed sink that keeps a single long-lived `FileHandle` open instead
/// of opening/seeking/closing the file on every line. Created lazily on first
/// write and reopened if a write fails (e.g. the file was rotated/removed).
final class BackgroundLogFileSink: BackgroundLogSink {
    private let url: URL
    private let fileManager: FileManager
    private var handle: FileHandle?

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = handle ?? openHandle() else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // The handle went stale (file removed/rotated). Drop it and retry
            // once with a fresh handle so we don't silently lose every
            // subsequent line.
            try? handle.close()
            self.handle = nil
            if let reopened = openHandle() {
                try? reopened.write(contentsOf: data)
            }
        }
    }

    private func openHandle() -> FileHandle? {
        if fileManager.fileExists(atPath: url.path) == false {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? opened.seekToEnd()
        handle = opened
        return opened
    }
}

/// Appends log lines without blocking the calling thread on disk I/O.
///
/// `logBackground` was previously a synchronous per-call `FileHandle` open →
/// `seekToEnd` → `write` → `close` that ran on whatever thread logged — often
/// the main thread during SwiftUI view updates. This batches the formatting and
/// the single write onto a private serial queue while capturing the ordering
/// metadata (sequence, timestamp, frame counters, originating thread) at call
/// time so output stays in submission order.
final class BackgroundLogWriter {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let sink: BackgroundLogSink
    private let queue: DispatchQueue
    private let startUptime: TimeInterval
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private let mediaTime: () -> TimeInterval
    private let sequenceLock = NSLock()
    private var sequence: UInt64 = 0

    init(
        sink: BackgroundLogSink,
        queue: DispatchQueue = DispatchQueue(label: "com.cmux.background-log", qos: .utility),
        startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
        now: @escaping () -> Date = { Date() },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        mediaTime: @escaping () -> TimeInterval = { CACurrentMediaTime() }
    ) {
        self.sink = sink
        self.queue = queue
        self.startUptime = startUptime
        self.now = now
        self.uptime = uptime
        self.mediaTime = mediaTime
    }

    convenience init(url: URL) {
        self.init(sink: BackgroundLogFileSink(url: url))
    }

    /// Capture ordering metadata on the calling thread (cheap value reads),
    /// then format and write on the serial queue so the caller never blocks on
    /// disk I/O.
    func append(_ message: String) {
        let date = now()
        let uptimeMs = (uptime() - startUptime) * 1000
        let media = mediaTime()
        let frame60 = Int((media * 60.0).rounded(.down))
        let frame120 = Int((media * 120.0).rounded(.down))
        let threadLabel = Thread.isMainThread ? "main" : "background"

        sequenceLock.lock()
        sequence &+= 1
        let sequence = sequence
        sequenceLock.unlock()

        let timestamp = Self.timestampFormatter.string(from: date)
        let line =
            "\(timestamp) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
        sink.write(line)
    }

    /// Block until all enqueued lines have been written. Used at app
    /// termination to preserve the previous flush-on-exit semantics.
    func flush() {
        queue.sync {}
    }
}
