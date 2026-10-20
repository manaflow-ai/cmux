import CmuxFoundation

/// Coalesces system and display wake notifications before rebuilding visible
/// terminal renderers.
@MainActor
final class TerminalWakeRendererRecoveryScheduler {
    private let scheduler: MainActorDeferredActionScheduler
    private var wakeEpisodeRecoveryRequested = false

    init() {
        scheduler = MainActorDeferredActionScheduler()
    }

    init(scheduler: MainActorDeferredActionScheduler) {
        self.scheduler = scheduler
    }

    func prepareForSleep() {
        wakeEpisodeRecoveryRequested = false
        scheduler.cancel()
    }

    func schedule(
        surfaces: @escaping @MainActor () -> [any TerminalWakeRendererRecoverable],
        reason: String
    ) {
        guard !wakeEpisodeRecoveryRequested else { return }
        wakeEpisodeRecoveryRequested = true
        scheduler.schedule(zeroDelayPolicy: .yieldOnce) {
            for surface in surfaces() where surface.isRendererEffectivelyVisible {
                surface.recoverRendererAfterWake(reason: reason)
            }
        }
    }
}
