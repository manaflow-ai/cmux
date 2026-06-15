public import Foundation

/// Serializes restored terminal runtime creation through a short cadence.
///
/// Restored terminals still appear in the UI immediately, but their native
/// Ghostty surface creation is spread across a small window so macOS does not
/// run every login shell's PAM and Launch Services work at once.
@MainActor
public final class TerminalSurfaceRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    /// Default spacing between restored terminal native spawns.
    public static let defaultInterSpawnDelay: Duration = .milliseconds(125)

    private let interSpawnDelay: Duration
    private let delayer: any TerminalSurfaceRestoreSpawnDelaying
    private var pending: [(surfaceId: UUID, operation: @MainActor () -> Void)] = []
    private var queuedSurfaceIds: Set<UUID> = []
    private var drainTask: Task<Void, Never>?

    /// Creates a scheduler for restored terminal native spawns.
    ///
    /// - Parameters:
    ///   - interSpawnDelay: The intended delay between native creation of two
    ///     restored terminal surfaces.
    ///   - delayer: The delay primitive; tests inject a manual implementation.
    public init(
        interSpawnDelay: Duration = TerminalSurfaceRestoreSpawnScheduler.defaultInterSpawnDelay,
        delayer: any TerminalSurfaceRestoreSpawnDelaying = ContinuousTerminalSurfaceRestoreSpawnDelayer()
    ) {
        self.interSpawnDelay = interSpawnDelay
        self.delayer = delayer
    }

    /// Enqueues one restored surface, coalescing duplicate readiness callbacks.
    public func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        operation: @escaping @MainActor () -> Void
    ) {
        guard !queuedSurfaceIds.contains(surfaceId) else { return }
        queuedSurfaceIds.insert(surfaceId)
        pending.append((surfaceId: surfaceId, operation: operation))
        guard drainTask == nil else { return }

        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            queuedSurfaceIds.remove(next.surfaceId)
            next.operation()

            if !pending.isEmpty, interSpawnDelay > .zero {
                await delayer.delay(for: interSpawnDelay)
            }
        }
        drainTask = nil
    }
}
