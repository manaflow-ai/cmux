import CmuxNextCompat
package import CmuxNextWakeups

/// The off-main half of hover preload (plans/cmux-next/hover-preload-DESIGN.md). The pointer's handler
/// (main thread, per row or tab change) only writes the target and the time under a lock and arms the
/// one timer when none is armed. The timer sleeps and the dwell check runs off the main thread; only a
/// target that held for the dwell hops to the main actor, once, to `onIntent`. A sweep over 200 rows
/// costs the main thread 200 lock writes and no hop.
package nonisolated final class HoverWakeGate: Sendable {
    private let intent: Mutex<HoverWakeIntent>
    private let timer: DemandTimer
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onIntent: @MainActor @Sendable (HoverWakeTarget) -> Void

    package init(owner: String, dwell: Duration = HoverWakeIntent.dwell, clock: any Clock<Duration> = ContinuousClock(),
                 now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                 onIntent: @escaping @MainActor @Sendable (HoverWakeTarget) -> Void) {
        intent = Mutex(HoverWakeIntent(dwell: dwell))
        timer = DemandTimer(owner: owner, clock: clock)
        self.now = now
        self.onIntent = onIntent
    }

    /// The pointer rests on `target` now (nil: on nothing). O(1), no hop.
    package func note(_ target: HoverWakeTarget?) {
        let at = now()
        guard let delay = intent.withLock({ $0.note(target, at: at) }) else { return }
        arm(after: delay)
    }

    package func cancel() {
        timer.cancel()
        intent.withLock { $0.reset() }
    }

    private func arm(after delay: Duration) {
        // Justified delay: the dwell itself (a one-shot deadline, not a poll); a later note never
        // re-arms it, the fire re-arms for the time left.
        timer.schedule(after: delay) { [weak self] in await self?.fire() }
    }

    private func fire() async {
        let at = now()
        switch intent.withLock({ $0.fire(at: at) }) {
        case .idle: return
        case let .rearm(left): arm(after: left)
        case let .intent(target): await deliver(target)
        }
    }

    /// On the main actor: the pointer may have left between the fire and this hop; then nothing wakes.
    @MainActor private func deliver(_ target: HoverWakeTarget) {
        guard intent.withLock({ $0.isResting(on: target) }) else { return }
        onIntent(target)
    }
}
