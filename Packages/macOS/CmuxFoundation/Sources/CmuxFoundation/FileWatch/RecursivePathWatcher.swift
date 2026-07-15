import Foundation

/// Stateful policy for folding raw filesystem identities into coalesced yields.
///
/// The watcher owns scheduling and stream lifecycle. This value owns only the
/// deterministic ordering, reset, and acknowledgement rules applied at those
/// boundaries.
struct FileWatchEventCoalescingState {
    private var isThrottleArmed = false
    private var pendingIdentity: FileWatchEventIdentity?
    private var conservativeIdentity: FileWatchEventIdentity?
    private var conservativeIdentityWasYielded = false

    /// Records a raw event and returns whether the caller must arm the throttle.
    mutating func record(_ identity: FileWatchEventIdentity) -> Bool {
        switch identity {
        case .stable:
            break
        case .mustRescan:
            conservativeIdentityWasYielded = false
            if conservativeIdentity != .eventIDsWrapped {
                conservativeIdentity = .mustRescan
            }
        case .eventIDsWrapped:
            conservativeIdentityWasYielded = false
            conservativeIdentity = .eventIDsWrapped
        }
        let effectiveIdentity = conservativeIdentity ?? identity
        pendingIdentity = pendingIdentity?.merged(with: effectiveIdentity)
            ?? effectiveIdentity
        guard !isThrottleArmed else { return false }
        isThrottleArmed = true
        return true
    }

    /// Ends the active window and returns the identity ready for delivery.
    mutating func takePendingIdentity() -> FileWatchEventIdentity? {
        isThrottleArmed = false
        defer { pendingIdentity = nil }
        return pendingIdentity
    }

    /// Reconciles conservative reset delivery with the output buffer's result.
    mutating func recordYield(
        _ result: AsyncStream<FileWatchEventIdentity>.Continuation.YieldResult
    ) {
        guard conservativeIdentity != nil else { return }
        switch result {
        case .enqueued:
            if conservativeIdentityWasYielded {
                conservativeIdentity = nil
                conservativeIdentityWasYielded = false
            } else {
                conservativeIdentityWasYielded = true
            }
        case .dropped:
            // The newest-element buffer replaced an unconsumed conservative
            // signal with the same conservative identity. Keep repeating it
            // until a later enqueue proves the consumer drained the buffer.
            conservativeIdentityWasYielded = true
        case .terminated:
            conservativeIdentityWasYielded = false
        @unknown default:
            conservativeIdentityWasYielded = false
        }
    }
}

/// Watches a set of filesystem paths recursively and reports changes as a
/// coalesced `AsyncStream<FileWatchEventIdentity>`.
///
/// Construct one with the paths to watch (the caller resolves which paths matter
/// for its domain) and consume ``events`` to react to changes:
///
/// ```swift
/// guard let watcher = RecursivePathWatcher(paths: paths) else { return }
/// let task = Task { @MainActor in
///     for await _ in watcher.events { reload() }
/// }
/// // later: task.cancel(); await watcher.stop()
/// ```
///
/// **Coalescing.** A leading-edge throttle folds a burst into one yield: the
/// first event in a window arms a single bounded delay (``FileWatchClock``) and
/// events arriving while that delay is pending are folded into it. Combined with
/// the underlying `FSEventStream` latency, the worst-case delay from a change to
/// an ``events`` element is roughly twice the throttle interval. During a
/// sustained storm an element is yielded at most once per window — it does *not*
/// wait for changes to stop, which keeps reactions responsive without per-event
/// churn.
///
/// **Construction.** The `FSEventStream` is created synchronously in ``init``,
/// so the watcher is already listening when it returns (nothing is missed in the
/// gap a deferred start would open) and ``init`` fails (`nil`) if the stream
/// cannot be created. The stream's `@Sendable` sink forwards into a private
/// raw-event `AsyncStream` rather than capturing the actor, which is what lets
/// creation happen in-`init`; a single actor-isolated pump drains that raw stream
/// and applies the throttle. The pump's lifetime is the raw stream's: ``stop()``
/// and `deinit` finish it.
public actor RecursivePathWatcher {
    /// The paths this watcher observes, as passed to ``init(paths:clock:)``.
    ///
    /// Exposed so callers can compare against a freshly resolved set and skip
    /// recreating an equivalent watcher.
    public nonisolated let watchedPaths: [String]

    /// Stream of coalesced change events with their FSEvents watermark.
    ///
    /// Independent watchers of the same path set receive the same identifier
    /// for the same underlying event, allowing process-wide consumers to
    /// coalesce duplicate delivery without a timing heuristic. The single
    /// newest-element buffer bounds memory while a consumer is busy. Stable IDs
    /// are cumulative watermarks. A dropped/wrapped batch remains conservative
    /// until a later yield proves the consumer drained that signal, then stable
    /// watermark delivery resumes.
    public nonisolated let events: AsyncStream<FileWatchEventIdentity>

    private let continuation: AsyncStream<FileWatchEventIdentity>.Continuation
    private let clock: any FileWatchClock
    private let eventSource: any FileWatchEventSource
    private var throttleTask: Task<Void, Never>?
    private var coalescingState = FileWatchEventCoalescingState()
    private var isStopped = false

    /// The `FSEventStream` coalescing latency, in seconds.
    private static let streamLatency = 0.25
    /// The leading-edge throttle window. Combined with ``streamLatency`` the
    /// worst-case change-to-yield delay is roughly twice this.
    private static let throttleInterval: Duration = .milliseconds(250)

    /// Creates and starts a watcher for `paths`.
    ///
    /// - Parameters:
    ///   - paths: The files and directories to watch. Must be non-empty.
    ///   - clock: The clock driving the coalescing throttle. Defaults to
    ///     ``SystemFileWatchClock``.
    /// - Returns: `nil` if `paths` is empty or the underlying `FSEventStream`
    ///   could not be created or started. On success the stream is already
    ///   listening.
    public init?(
        paths: [String],
        clock: any FileWatchClock = SystemFileWatchClock()
    ) {
        guard !paths.isEmpty else { return nil }
        guard let eventSource = FileSystemEventStream(
            paths: paths,
            latency: Self.streamLatency
        ) else { return nil }
        self.init(watchedPaths: paths, eventSource: eventSource, clock: clock)
    }

    /// Creates a watcher over an event source.
    ///
    /// The FSEvents transport and coalescing pipeline have separate ownership so
    /// alternate event transports can reuse the same ordering, reset, buffering,
    /// and lifecycle behavior.
    init(
        watchedPaths: [String],
        eventSource: any FileWatchEventSource,
        clock: any FileWatchClock = SystemFileWatchClock()
    ) {
        self.watchedPaths = watchedPaths
        self.clock = clock
        self.eventSource = eventSource
        let (events, continuation) = AsyncStream<FileWatchEventIdentity>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = continuation
        let rawEvents = eventSource.events

        // Drain raw FS events through the actor-isolated throttle. Started last so
        // init touches no isolated state after `self` escapes into the task; it
        // holds `self` weakly and ends when `rawEvents` finishes (stop/deinit).
        Task { [weak self] in
            for await identity in rawEvents {
                await self?.handleRawEvent(identity: identity)
            }
        }
    }

    /// Stops the watcher, tears down the underlying stream, and finishes
    /// ``events``. Idempotent.
    public func stop() {
        isStopped = true
        throttleTask?.cancel()
        throttleTask = nil
        eventSource.stop()
        continuation.finish()
    }

    deinit {
        // FSEventStream teardown is synchronous and thread-safe; finishing the
        // continuations ends the pump and any consumer.
        eventSource.stop()
        throttleTask?.cancel()
        continuation.finish()
    }

    /// Leading-edge throttle entry point. The first event of a window arms one
    /// delay; events arriving while it is pending are no-ops (the `throttleTask
    /// == nil` guard), so a burst yields a single ``events`` element.
    private func handleRawEvent(identity: FileWatchEventIdentity) {
        guard !isStopped else { return }
        guard coalescingState.record(identity) else { return }
        let clock = self.clock
        let interval = Self.throttleInterval
        throttleTask = Task { [weak self] in
            try? await clock.sleep(for: interval)
            await self?.flushThrottle()
        }
    }

    private func flushThrottle() {
        throttleTask = nil
        guard !isStopped, let identity = coalescingState.takePendingIdentity() else { return }
        let result = continuation.yield(identity)
        coalescingState.recordYield(result)
    }
}
