import CmuxFoundation

@MainActor
final class SidebarResizerCursorReleaseScheduler {
    private let scheduler: MainActorDeferredActionScheduler

    init(clock: any Clock<Duration> = ContinuousClock()) {
        scheduler = MainActorDeferredActionScheduler(clock: clock)
    }

    func cancelPendingRelease() {
        scheduler.cancel()
    }

    func schedule(
        force: Bool,
        delay: Duration,
        release: @escaping @MainActor (Bool) -> Void
    ) {
        scheduler.schedule(after: delay, zeroDelayPolicy: .yieldOnce) {
            release(force)
        }
    }
}
