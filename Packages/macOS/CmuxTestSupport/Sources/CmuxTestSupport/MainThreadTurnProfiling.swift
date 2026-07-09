#if DEBUG
public import Foundation

/// Seam for the DEBUG main-thread run-loop turn profiler.
///
/// The app's composition root constructs a concrete profiler
/// (``CmuxMainThreadTurnProfiler``) and holds it as `any MainThreadTurnProfiling`,
/// calling ``installIfNeeded()`` once during launch. The profiler attaches a
/// `CFRunLoopObserver` to the main run loop, accumulates per-bucket time recorded
/// via ``endMeasure(_:startedAt:)`` within a single run-loop turn, and emits a
/// `main.turn.work` line when a turn's tracked time or sample count crosses the
/// internal thresholds. Inverting both entry points behind this protocol lets the
/// app drop the former `static let shared` singleton in favor of one
/// constructor-injected instance; ``CmuxTypingTiming`` forwards its
/// `logDuration` measurements to the same injected instance instead of a static
/// `shared`.
///
/// Isolation: the protocol is `Sendable` but not actor-isolated, because
/// ``endMeasure(_:startedAt:)`` is forwarded from
/// ``CmuxTypingTiming/logDuration(path:startedAt:event:extra:)`` on the typing
/// hot path (a nonisolated static API) and cannot pay an actor hop. All mutation
/// is nonetheless main-thread-confined by construction: `endMeasure` only acts
/// when `Thread.isMainThread`, `installIfNeeded()` is called on the main actor at
/// launch, and the observer callback fires on the main run loop. The conformer
/// documents this confinement and its `@unchecked Sendable` justification.
public protocol MainThreadTurnProfiling: AnyObject, Sendable {
    /// Attaches the main-run-loop turn observer the first time it is called,
    /// gated by the typing-timing probe being enabled. Subsequent calls are
    /// no-ops once installed.
    func installIfNeeded()

    /// Records the elapsed time of one measured span into the current run-loop
    /// turn's `bucket`. Ignored unless a `startedAt` is supplied, the typing
    /// probe is enabled, and the call is on the main thread.
    func endMeasure(_ bucket: String, startedAt: TimeInterval?)
}
#endif
