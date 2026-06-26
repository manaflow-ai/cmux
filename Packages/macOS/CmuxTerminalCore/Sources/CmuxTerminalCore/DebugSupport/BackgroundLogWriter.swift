public import Foundation
import QuartzCore

/// Asynchronous, append-only sink for cmux's opt-in background diagnostics log.
///
/// This replaces the former inline `GhosttyApp.logBackground` implementation,
/// which formatted a timestamp and did a synchronous `FileManager.fileExists`
/// check plus a `FileHandle` open → `seekToEnd` → `write` → `close` *per line*,
/// on whatever thread emitted the event. Appearance resolution emits these from
/// SwiftUI view updates, so the disk I/O landed on the main thread inside
/// AttributeGraph updates — see
/// https://github.com/manaflow-ai/cmux/issues/5833.
///
/// Callers now pay only for capturing a few cheap timing values (`Date`,
/// `systemUptime`, `CACurrentMediaTime`, and the calling thread's main/background
/// label). All string formatting and file I/O run on a single dedicated serial
/// queue against one long-lived file handle, so emitting a log line never blocks
/// the calling thread on disk.
///
/// Ordering and the monotonic `seq=` counter are preserved because the drain
/// queue is serial and FIFO.
public final class BackgroundLogWriter: @unchecked Sendable {
    private let fileURL: URL
    private let startUptime: TimeInterval
    private let queue: DispatchQueue

    // Everything below is confined to `queue`; it must never be read or written
    // from any other thread. The class is `@unchecked Sendable` on the strength
    // of that confinement.
    private var handle: FileHandle?
    private var handleResolved = false
    private var sequence: UInt64 = 0
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Creates a writer that appends to `fileURL`. `startUptime` is the
    /// `ProcessInfo.systemUptime` baseline used to compute the relative
    /// `t+…ms` field; capture it once at app launch so every line shares the
    /// same origin.
    public init(fileURL: URL, startUptime: TimeInterval) {
        self.fileURL = fileURL
        self.startUptime = startUptime
        self.queue = DispatchQueue(label: "com.cmuxterm.background-log", qos: .utility)
    }

    /// Enqueues `message` for asynchronous append and returns immediately.
    ///
    /// `isMainThread` is supplied by the caller because the drain queue is never
    /// the main thread; capturing it here on the calling thread preserves the
    /// `thread=main`/`thread=background` field's meaning.
    public func log(_ message: String, isMainThread: Bool) {
        // Captured on the calling thread (all cheap, no formatting / no I/O).
        let capturedDate = Date()
        let uptimeMs = (ProcessInfo.processInfo.systemUptime - startUptime) * 1000
        let mediaTime = CACurrentMediaTime()
        let threadLabel = isMainThread ? "main" : "background"

        queue.async { [self] in
            sequence &+= 1
            let frame60 = Int((mediaTime * 60.0).rounded(.down))
            let frame120 = Int((mediaTime * 120.0).rounded(.down))
            let line =
                "\(timestampFormatter.string(from: capturedDate)) seq=\(sequence) t+\(String(format: "%.3f", uptimeMs))ms thread=\(threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(message)\n"
            guard let data = line.data(using: .utf8), let handle = resolvedHandle() else { return }
            try? handle.write(contentsOf: data)
        }
    }

    /// Blocks until every previously-enqueued line has been written. For tests
    /// and orderly shutdown only; production callers never need it.
    public func drain() {
        queue.sync {}
    }

    // MARK: - Queue-confined

    /// Lazily opens (and seeks to end of) the single long-lived file handle on
    /// the serial queue. Returns `nil` if the file cannot be opened; subsequent
    /// calls keep returning the cached result rather than retrying per line.
    private func resolvedHandle() -> FileHandle? {
        if handleResolved {
            return handle
        }
        handleResolved = true
        let path = fileURL.path
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: fileURL)
        try? opened?.seekToEnd()
        handle = opened
        return opened
    }
}
