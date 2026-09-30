public import Foundation
// `public` because the designated initializer's default `now` closure references
// `CACurrentMediaTime()` in a default-argument position, which is emitted into
// clients and so cannot reference an internal-imported symbol.
public import QuartzCore

/// Captures the timing values stamped onto a background-log line, sampled on the
/// calling thread when an event is emitted. Injectable so tests can supply
/// deterministic values instead of wall-clock / media-time reads.
public typealias BackgroundLogClock = @Sendable () -> (
    date: Date, systemUptime: TimeInterval, mediaTime: Double
)

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
/// `log(_:isMainThread:)` only samples a few cheap timing values (via the injected
/// ``BackgroundLogClock``) and `yield`s them onto an `AsyncStream`, then returns.
/// A single long-lived consumer task formats each entry and hands the line to the
/// injected ``BackgroundLogLineSink`` (production: ``FileBackgroundLogLineSink``).
/// All mutable state is task-local, so the type is plain `Sendable` — no
/// `@unchecked` escape hatch, no locks, no dispatch-queue barriers. `AsyncStream`
/// delivers yields FIFO to its one consumer, preserving emission order and the
/// monotonic `seq=` field.
///
/// The buffer is bounded (`maxBufferedEntries`, drop-oldest): the consumer keeps
/// it near empty in steady state, but if emitters ever outpace the sink — e.g.
/// opt-in diagnostics during a burst on stalled storage — the oldest buffered
/// entries are dropped rather than growing memory without limit. Delivered lines
/// keep contiguous `seq=` numbering; dropped entries never reach the consumer.
///
/// The filesystem and clock are injected (rather than hard-coded) so the package
/// boundary stays deterministically testable, matching this package's
/// injectable-seam convention (e.g. `GhosttyConfig.load(loadFromDisk:)`).
public final class BackgroundLogWriter: Sendable {
    private let startUptime: TimeInterval
    private let now: BackgroundLogClock
    private let continuation: AsyncStream<BackgroundLogEntry>.Continuation

    /// Designated initializer: inject the line `sink` and (optionally) the clock.
    ///
    /// `startUptime` is the `systemUptime` baseline for the relative `t+…ms` field.
    /// `maxBufferedEntries` bounds the in-flight buffer (clamped to at least 1);
    /// the default of 8192 — a few hundred bytes each, so a few MB worst case — is
    /// far above any real diagnostics rate, and the cap only engages if emitters
    /// outpace the sink, dropping the oldest buffered entries.
    public init(
        startUptime: TimeInterval,
        sink: any BackgroundLogLineSink,
        now: @escaping BackgroundLogClock = {
            (Date(), ProcessInfo.processInfo.systemUptime, CACurrentMediaTime())
        },
        maxBufferedEntries: Int = 8192
    ) {
        self.startUptime = startUptime
        self.now = now
        let (stream, continuation) = AsyncStream<BackgroundLogEntry>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, maxBufferedEntries))
        )
        self.continuation = continuation
        // One detached consumer for the lifetime of the writer: it must outlive
        // every (unstructured) caller of `log`, so it is intentionally not a child
        // of any caller's task tree. It does not capture `self`, so the writer can
        // deinit and end the stream.
        Task.detached(priority: .utility) {
            await consumeBackgroundLog(stream, sink: sink)
        }
    }

    /// Convenience initializer for production: append to `fileURL` with the real
    /// wall-clock. Used by the app; the call site stays a single URL + baseline.
    public convenience init(
        fileURL: URL,
        startUptime: TimeInterval,
        maxBufferedEntries: Int = 8192
    ) {
        self.init(
            startUptime: startUptime,
            sink: FileBackgroundLogLineSink(fileURL: fileURL),
            maxBufferedEntries: maxBufferedEntries
        )
    }

    deinit {
        // Ends the consumer's `for await` loop so it does not outlive the writer
        // (matters for tests that create short-lived writers).
        continuation.finish()
    }

    /// Samples timing on the calling thread and enqueues `message` for asynchronous
    /// append; returns immediately.
    ///
    /// `isMainThread` is supplied by the caller because the consumer task is never
    /// the main thread; capturing it here preserves the `thread=main`/
    /// `thread=background` field's meaning.
    public func log(_ message: String, isMainThread: Bool) {
        let reading = now()
        continuation.yield(
            (
                message: message,
                date: reading.date,
                uptimeMs: (reading.systemUptime - startUptime) * 1000,
                mediaTime: reading.mediaTime,
                threadLabel: isMainThread ? "main" : "background"
            )
        )
    }
}

/// One emitted event, with its timing captured on the calling thread, carried to
/// the consumer task as `Sendable` value data. A tuple (not a named type) keeps
/// it a private, file-local hand-off with no meaning outside this sink.
private typealias BackgroundLogEntry = (
    message: String,
    date: Date,
    uptimeMs: Double,
    mediaTime: Double,
    threadLabel: String
)

/// The single consumer: formats each entry and forwards the line to `sink`, in
/// stream (FIFO) order. The `seq` counter and formatter are local to this call,
/// so it needs no synchronization.
private func consumeBackgroundLog(
    _ stream: AsyncStream<BackgroundLogEntry>,
    sink: any BackgroundLogLineSink
) async {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var sequence: UInt64 = 0

    for await entry in stream {
        sequence &+= 1
        let frame60 = Int((entry.mediaTime * 60.0).rounded(.down))
        let frame120 = Int((entry.mediaTime * 120.0).rounded(.down))
        let line =
            "\(formatter.string(from: entry.date)) seq=\(sequence) t+\(String(format: "%.3f", entry.uptimeMs))ms thread=\(entry.threadLabel) frame60=\(frame60) frame120=\(frame120) cmux bg: \(entry.message)\n"
        await sink.write(line)
    }
}
