public import Foundation

/// Schedules coalesced, cancellable, bounded terminal-state evaluations.
///
/// One persistent consumer task exists per registered surface. Rapid PTY
/// invalidations overwrite one buffered revision, while evaluation waits for
/// a quiet window or the burst's maximum latency. Results whose revision became
/// stale during capture are discarded, and observers receive effective changes only.
public actor AgentTerminalStateDetectionScheduler {
    private let clock: AgentTerminalDetectionClock
    private let configuration: AgentTerminalDetectionConfiguration
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var lastEvaluatedRevision: [UUID: UInt64] = [:]
    private var lastPublished: [UUID: AgentTerminalStateClassification] = [:]

    /// Creates a scheduler with an injected clock for deterministic timing tests.
    public init(clock: AgentTerminalDetectionClock, configuration: AgentTerminalDetectionConfiguration = .init()) {
        self.clock = clock
        self.configuration = configuration
    }

    /// Starts or replaces detection for one surface.
    ///
    /// - Parameters:
    ///   - surfaceID: Stable surface identifier.
    ///   - signal: Synchronous dirty signal installed in the PTY tee.
    ///   - evaluate: Deferred snapshot/classification operation for a requested revision.
    ///   - deliver: Per-surface delivery that cannot overwrite another surface's update.
    public func start(
        surfaceID: UUID,
        signal: AgentTerminalDirtySignal,
        evaluate: @escaping @Sendable (_ revision: UInt64) async -> AgentTerminalStateClassification?,
        deliver: @escaping @Sendable (AgentTerminalDetectionUpdate) async -> Void
    ) {
        stop(surfaceID: surfaceID)
        tasks[surfaceID] = Task { [weak self] in
            await self?.consume(
                surfaceID: surfaceID,
                signal: signal,
                evaluate: evaluate,
                deliver: deliver
            )
        }
    }

    /// Cancels detection and clears cached state for one surface.
    public func stop(surfaceID: UUID) {
        tasks.removeValue(forKey: surfaceID)?.cancel()
        lastEvaluatedRevision.removeValue(forKey: surfaceID)
        lastPublished.removeValue(forKey: surfaceID)
    }

    /// Cancels every registered surface.
    public func stopAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        lastEvaluatedRevision.removeAll()
        lastPublished.removeAll()
    }

    private func consume(
        surfaceID: UUID,
        signal: AgentTerminalDirtySignal,
        evaluate: @escaping @Sendable (UInt64) async -> AgentTerminalStateClassification?,
        deliver: @escaping @Sendable (AgentTerminalDetectionUpdate) async -> Void
    ) async {
        for await receivedRevision in signal.revisions {
            guard !Task.isCancelled else { return }
            guard receivedRevision > (lastEvaluatedRevision[surfaceID] ?? 0) else { continue }
            let burstStartedAt = await clock.now()
            var observedRevision = signal.currentRevision()

            while !Task.isCancelled {
                let elapsed = await clock.now() - burstStartedAt
                if elapsed >= configuration.maximumLatency { break }
                let remaining = configuration.maximumLatency - elapsed
                let delay = min(configuration.quietWindow, remaining)
                let beforeDelay = signal.currentRevision()
                do {
                    // This is the intended cancellable debounce/deadline delay.
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
                observedRevision = signal.currentRevision()
                if observedRevision == beforeDelay { break }
            }

            guard !Task.isCancelled else { return }
            let revision = max(observedRevision, receivedRevision)
            guard revision > (lastEvaluatedRevision[surfaceID] ?? 0) else { continue }
            var classification = await evaluate(revision)
            if classification == nil, !Task.isCancelled, signal.currentRevision() == revision {
                do {
                    try await clock.sleep(for: configuration.quietWindow)
                } catch {
                    return
                }
                if !Task.isCancelled, signal.currentRevision() == revision {
                    classification = await evaluate(revision)
                }
            }
            guard let classification else { continue }
            guard !Task.isCancelled, signal.currentRevision() == revision else { continue }
            lastEvaluatedRevision[surfaceID] = revision
            guard lastPublished[surfaceID] != classification else { continue }
            lastPublished[surfaceID] = classification
            await deliver(AgentTerminalDetectionUpdate(
                surfaceID: surfaceID,
                revision: revision,
                classification: classification
            ))
        }
    }
}
