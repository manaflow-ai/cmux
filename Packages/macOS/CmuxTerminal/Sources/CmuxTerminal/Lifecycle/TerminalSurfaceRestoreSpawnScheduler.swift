public import Foundation

/// Serializes restored terminal runtime creation through a short cadence.
///
/// Restored terminals still appear in the UI immediately, but their native
/// Ghostty surface creation is spread across a small window so macOS does not
/// run every login shell's PAM and Launch Services work at once. A restored
/// agent resume (Codex, Claude and the like) holds a longer cooldown, so a
/// window with many agent panes does not start every agent process together.
@MainActor
public final class TerminalSurfaceRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    /// Default spacing between restored terminal native spawns.
    public static let defaultInterSpawnDelay: Duration = .milliseconds(125)
    /// Default spacing after a restored agent resume's native spawn.
    public static let defaultAgentResumeInterSpawnDelay: Duration = .milliseconds(750)

    private let interSpawnDelay: Duration
    private let agentResumeInterSpawnDelay: Duration
    private let delayer: any TerminalSurfaceRestoreSpawnDelaying
    private var pending: [(surfaceId: UUID, resumesAgent: Bool, operation: @MainActor () -> Void)] = []
    private var pendingHead = 0
    private var queuedSurfaceIds: Set<UUID> = []
    private var isDraining = false
    private var drainStartTask: Task<Void, Never>?
    private var scheduledDelay: (any TerminalSurfaceRestoreSpawnDelayCancelling)?

    /// Creates a scheduler for restored terminal native spawns.
    ///
    /// - Parameters:
    ///   - interSpawnDelay: The intended delay between native creation of two
    ///     restored terminal surfaces.
    ///   - agentResumeInterSpawnDelay: The delay after a restored agent
    ///     resume's native creation; the larger of the two delays applies.
    ///   - delayer: The delay primitive; tests inject a manual implementation.
    public init(
        interSpawnDelay: Duration = TerminalSurfaceRestoreSpawnScheduler.defaultInterSpawnDelay,
        agentResumeInterSpawnDelay: Duration =
            TerminalSurfaceRestoreSpawnScheduler.defaultAgentResumeInterSpawnDelay,
        delayer: any TerminalSurfaceRestoreSpawnDelaying = RunLoopTerminalSurfaceRestoreSpawnDelayer()
    ) {
        self.interSpawnDelay = interSpawnDelay
        self.agentResumeInterSpawnDelay = agentResumeInterSpawnDelay
        self.delayer = delayer
    }

    /// Enqueues one restored surface, coalescing duplicate readiness callbacks.
    public func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        resumesAgent: Bool,
        operation: @escaping @MainActor () -> Void
    ) {
        guard !queuedSurfaceIds.contains(surfaceId) else { return }
        queuedSurfaceIds.insert(surfaceId)
        pending.append((surfaceId: surfaceId, resumesAgent: resumesAgent, operation: operation))
        guard !isDraining, drainStartTask == nil else { return }

        drainStartTask = Task { @MainActor [weak self] in
            self?.beginDraining()
        }
    }

    private func beginDraining() {
        drainStartTask = nil
        guard !isDraining else { return }
        guard pendingHead < pending.count else { return }
        isDraining = true
        drainNextReadySpawn()
    }

    private func drainNextReadySpawn() {
        while pendingHead < pending.count {
            let next = pending[pendingHead]
            pendingHead += 1
            queuedSurfaceIds.remove(next.surfaceId)
            next.operation()

            let cooldown = next.resumesAgent
                ? max(interSpawnDelay, agentResumeInterSpawnDelay)
                : interSpawnDelay
            if cooldown > .zero {
                schedulePostSpawnCooldown(cooldown)
                return
            }
        }
        finishDraining()
    }

    private func schedulePostSpawnCooldown(_ cooldown: Duration) {
        scheduledDelay = delayer.scheduleDelay(for: cooldown) { [weak self] in
            guard let self else { return }
            self.scheduledDelay = nil
            if self.pendingHead < self.pending.count {
                self.drainNextReadySpawn()
            } else {
                self.finishDraining()
            }
        }
    }

    private func finishDraining() {
        pending.removeAll(keepingCapacity: true)
        pendingHead = 0
        queuedSurfaceIds.removeAll(keepingCapacity: true)
        isDraining = false
    }
}
