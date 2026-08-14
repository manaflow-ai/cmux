import Foundation

/// Watches a set of filesystem paths recursively and reports coalesced changes.
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
/// **Coalescing.** A leading-edge debounce window folds a burst into one yield: the
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
public struct RecursivePathChange: Equatable, Sendable {
    /// Absolute paths reported during one bounded coalescing window.
    public let paths: [String]

    /// The OS dropped history or the bounded path buffer overflowed. Consumers
    /// must conservatively re-check their authoritative state when this is true.
    public let requiresFullRescan: Bool

    public init(paths: [String], requiresFullRescan: Bool = false) {
        self.paths = paths
        self.requiresFullRescan = requiresFullRescan
    }
}

public actor RecursivePathWatcher {
    /// The paths this watcher observes, as passed to ``init(paths:clock:)``.
    ///
    /// Exposed so callers can compare against a freshly resolved set and skip
    /// recreating an equivalent watcher.
    public nonisolated let watchedPaths: [String]

    /// Stream of coalesced change events. Yields one element per throttle window
    /// in which at least one filesystem event affected a watched path. Finishes
    /// when ``stop()`` is called or the watcher is deallocated.
    public nonisolated let events: AsyncStream<Void>

    /// Path-aware counterpart to ``events``. Consumers that can reject
    /// irrelevant changes should prefer this stream.
    public nonisolated let pathEvents: AsyncStream<RecursivePathChange>

    private let continuation: AsyncStream<Void>.Continuation
    private let pathContinuation: AsyncStream<RecursivePathChange>.Continuation
    private let clock: any FileWatchClock
    private let eventFilter: @Sendable (RecursivePathChange) -> Bool
    // nil only for the test-throttle initializer, which drives the throttle
    // directly without a real FSEventStream.
    private let eventStream: FileSystemEventStream?
    // Finishing this ends the pump task (see init); raw FS events flow through it.
    private let rawContinuation: AsyncStream<FileSystemEventBatch>.Continuation
    private var pendingPaths: Set<String> = []
    private var pendingRequiresFullRescan = false
    private var throttleTask: Task<Void, Never>?
    private var isStopped = false

    /// The `FSEventStream` coalescing latency, in seconds.
    private static let streamLatency = 0.25
    /// The leading-edge throttle window. Combined with ``streamLatency`` the
    /// worst-case change-to-yield delay is roughly twice this.
    private static let throttleInterval: Duration = .milliseconds(250)
    /// Bounds path accumulation across multiple callbacks in one window.
    private static let maximumPendingPathCount = 4_096

    /// Creates and starts a watcher for `paths`.
    ///
    /// - Parameters:
    ///   - paths: The files and directories to watch. Must be non-empty.
    ///   - clock: The clock driving the coalescing throttle. Defaults to
    ///     ``SystemFileWatchClock``.
    ///   - eventFilter: A fast, non-blocking predicate applied before a batch
    ///     arms the debounce. Overflow markers always pass through.
    /// - Returns: `nil` if `paths` is empty or the underlying `FSEventStream`
    ///   could not be created or started. On success the stream is already
    ///   listening.
    public init?(
        paths: [String],
        clock: any FileWatchClock = SystemFileWatchClock(),
        eventFilter: @escaping @Sendable (RecursivePathChange) -> Bool = { _ in true }
    ) {
        guard !paths.isEmpty else { return nil }
        self.watchedPaths = paths
        self.clock = clock
        self.eventFilter = eventFilter
        let (events, eventsContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = eventsContinuation
        let (pathEvents, pathContinuation) = AsyncStream<RecursivePathChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.pathEvents = pathEvents
        self.pathContinuation = pathContinuation
        let (rawEvents, rawContinuation) = AsyncStream<FileSystemEventBatch>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        self.rawContinuation = rawContinuation

        // The sink captures `rawContinuation` (a Sendable value), not `self`, so
        // the stream can be created synchronously here without escaping the
        // actor mid-init.
        guard let eventStream = FileSystemEventStream(
            paths: paths,
            latency: Self.streamLatency,
            onEvent: { batch in
                if case .dropped = rawContinuation.yield(batch) {
                    // The bounded callback queue lost history. Enqueue a marker
                    // that makes the eventual consumer re-check conservatively.
                    rawContinuation.yield(FileSystemEventBatch(
                        paths: [],
                        requiresFullRescan: true
                    ))
                }
            }
        ) else {
            eventsContinuation.finish()
            pathContinuation.finish()
            rawContinuation.finish()
            return nil
        }
        self.eventStream = eventStream

        // Drain raw FS events through the actor-isolated throttle. Started last so
        // init touches no isolated state after `self` escapes into the task; it
        // holds `self` weakly and ends when `rawEvents` finishes (stop/deinit).
        Task { [weak self] in
            for await batch in rawEvents {
                await self?.handleRawEvent(batch)
            }
        }
    }

    /// Creates a watcher with no underlying `FSEventStream`, driven only by
    /// ``simulateFileSystemEventForTesting()``.
    ///
    /// Used by the package tests to exercise the coalescing throttle in isolation
    /// with an injected clock and no real filesystem dependency.
    init(
        testThrottleClock clock: any FileWatchClock,
        eventFilter: @escaping @Sendable (RecursivePathChange) -> Bool = { _ in true }
    ) {
        self.watchedPaths = []
        self.clock = clock
        self.eventFilter = eventFilter
        let (events, eventsContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = events
        self.continuation = eventsContinuation
        let (pathEvents, pathContinuation) = AsyncStream<RecursivePathChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.pathEvents = pathEvents
        self.pathContinuation = pathContinuation
        let (_, rawContinuation) = AsyncStream<FileSystemEventBatch>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.rawContinuation = rawContinuation
        self.eventStream = nil
    }

    /// Stops the watcher, tears down the underlying stream, and finishes
    /// ``events``. Idempotent.
    public func stop() {
        isStopped = true
        throttleTask?.cancel()
        throttleTask = nil
        eventStream?.stop()
        rawContinuation.finish()
        continuation.finish()
        pathContinuation.finish()
    }

    deinit {
        // FSEventStream teardown is synchronous and thread-safe; finishing the
        // continuations ends the pump and any consumer.
        eventStream?.stop()
        throttleTask?.cancel()
        rawContinuation.finish()
        continuation.finish()
        pathContinuation.finish()
    }

    /// Leading-edge throttle entry point. The first event of a window arms one
    /// delay; events arriving while it is pending are no-ops (the `throttleTask
    /// == nil` guard), so a burst yields a single ``events`` element.
    private func handleRawEvent(_ batch: FileSystemEventBatch) {
        guard !isStopped else { return }
        let rawChange = RecursivePathChange(
            paths: batch.paths,
            requiresFullRescan: batch.requiresFullRescan
        )
        guard batch.requiresFullRescan || eventFilter(rawChange) else { return }
        if batch.requiresFullRescan
            || pendingPaths.count + batch.paths.count > Self.maximumPendingPathCount {
            pendingRequiresFullRescan = true
            pendingPaths.removeAll(keepingCapacity: true)
        } else if !pendingRequiresFullRescan {
            pendingPaths.formUnion(batch.paths)
        }
        guard throttleTask == nil else { return }
        let clock = self.clock
        let interval = Self.throttleInterval
        throttleTask = Task { [weak self] in
            try? await clock.sleep(for: interval)
            await self?.flushThrottle()
        }
    }

    private func flushThrottle() {
        throttleTask = nil
        guard !isStopped else { return }
        let change = RecursivePathChange(
            paths: pendingPaths.sorted(),
            requiresFullRescan: pendingRequiresFullRescan
        )
        pendingPaths.removeAll(keepingCapacity: true)
        pendingRequiresFullRescan = false
        pathContinuation.yield(change)
        continuation.yield(())
    }

    /// Feeds a synthetic filesystem event into the throttle. Test-only seam used
    /// by ``init(testThrottleClock:)``-constructed watchers.
    func simulateFileSystemEventForTesting(
        paths: [String] = [],
        requiresFullRescan: Bool = false
    ) {
        handleRawEvent(FileSystemEventBatch(
            paths: paths,
            requiresFullRescan: requiresFullRescan
        ))
    }
}
