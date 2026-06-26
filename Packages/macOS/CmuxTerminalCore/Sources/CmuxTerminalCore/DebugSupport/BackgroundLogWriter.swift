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
/// Callers (`log(_:isMainThread:)`) only capture a few cheap timing values and
/// `yield` them onto an `AsyncStream`; a single long-lived consumer task owns the
/// `FileHandle`, the `seq` counter, and the `DateFormatter`, so those mutable
/// fields get task-local isolation with no shared state — the type is therefore
/// plain `Sendable` (no `@unchecked` escape hatch) and uses no locks or
/// dispatch-queue barriers. `AsyncStream` delivers yields in FIFO order to its
/// one consumer, which preserves emission order and the monotonic `seq=` field.
public final class BackgroundLogWriter: Sendable {
    /// One emitted event, with its timing captured on the calling thread. All
    /// fields are value types so the entry crosses to the consumer task as
    /// `Sendable` data.
    private struct Entry: Sendable {
        let message: String
        let date: Date
        let uptimeMs: Double
        let mediaTime: Double
        let threadLabel: String
    }

    private let startUptime: TimeInterval
    private let continuation: AsyncStream<Entry>.Continuation

    /// Creates a writer that appends to `fileURL`. `startUptime` is the
    /// `ProcessInfo.systemUptime` baseline used to compute the relative
    /// `t+…ms` field; capture it once at app launch so every line shares the
    /// same origin.
    public init(fileURL: URL, startUptime: TimeInterval) {
        self.startUptime = startUptime
        // `.unbounded` matches the prior `queue.async` backlog (lines are never
        // dropped). The consumer drains continuously, so the buffer is ~empty in
        // steady state and only grows transiently while opt-in debug logging is on.
        let (stream, continuation) = AsyncStream<Entry>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        // One detached consumer for the lifetime of the writer: it must outlive
        // every (unstructured) caller of `log`, so it is intentionally not a child
        // of any caller's task tree. It does not capture `self`, so the writer can
        // deinit and end the stream.
        Task.detached(priority: .utility) {
            await BackgroundLogWriter.consume(stream, fileURL: fileURL)
        }
    }

    deinit {
        // Ends the consumer's `for await` loop so it does not outlive the writer
        // (matters for tests that create short-lived writers).
        continuation.finish()
    }

    /// Captures `message` plus cheap timing values on the calling thread and
    /// enqueues them for asynchronous append; returns immediately.
    ///
    /// `isMainThread` is supplied by the caller because the consumer task is never
    /// the main thread; capturing it here preserves the `thread=main`/
    /// `thread=background` field's meaning.
    public func log(_ message: String, isMainThread: Bool) {
        continuation.yield(
            Entry(
                message: message,
                date: Date(),
                uptimeMs: (ProcessInfo.processInfo.systemUptime - startUptime) * 1000,
                mediaTime: CACurrentMediaTime(),
                threadLabel: isMainThread ? "main" : "background"
            )
        )
    }

    /// The single consumer: formats each entry and appends it through one
    /// long-lived handle, in stream (FIFO) order. All mutable state is local to
    /// this task.
    private static func consume(_ stream: AsyncStream<Entry>, fileURL: URL) async {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var handle: FileHandle?
        var handleResolved = false
        var sequence: UInt64 = 0

        for await entry in stream {
            sequence &+= 1
            let frame60 = Int((entry.mediaTime * 60.0).rounded(.down))
            let frame120 = Int((entry.mediaTime * 120.0).rounded(.down))
            let line =
                "\(formatter.string(from: entry.date)) seq=\(sequence) t+\(String(format: "%.3f", entry.uptimeMs))ms thread=\(entry.threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(entry.message)\n"

            if !handleResolved {
                handleResolved = true
                handle = openHandle(fileURL: fileURL)
            }
            guard let data = line.data(using: .utf8), let handle else { continue }
            try? handle.write(contentsOf: data)
        }
        try? handle?.close()
    }

    /// Opens (and seeks to end of) the single long-lived file handle, creating the
    /// file if needed. Called once by the consumer on its first entry.
    private static func openHandle(fileURL: URL) -> FileHandle? {
        let path = fileURL.path
        if FileManager.default.fileExists(atPath: path) == false {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        try? handle?.seekToEnd()
        return handle
    }
}
