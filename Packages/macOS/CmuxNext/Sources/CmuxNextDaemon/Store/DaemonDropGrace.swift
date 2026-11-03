public import CmuxNextWakeups
public import Observation

/// A drop's grace (`DaemonStore.dropGrace`): active for `duration` after a connection that was up
/// ends, until one is up again. A restart or a version handoff reconnects within it, so surfaces
/// keep saying connecting (the Chief row) instead of flashing "Unreachable"; a drop that lasts
/// shows once it ends. Only a drop starts it: a first connect that
/// has not succeeded is `.connecting` until the startup deadline (`DaemonStartupState.showsFailure`).
/// Stop condition: one `DemandTimer` per drop, cancelled by a reconnect or the next drop.
@Observable @MainActor
public final class DaemonDropGrace {
    public private(set) var isActive = false
    /// The startup deadline the window waits too.
    @ObservationIgnored public var duration: Duration = DaemonStartup.shared.defaultDeadline
    /// Tests inject a clock that does not wait.
    @ObservationIgnored public var clock: any Clock<Duration> = ContinuousClock()
    @ObservationIgnored private var timer: DemandTimer?

    public init() {}

    func note(_ old: DaemonConnectionState, _ new: DaemonConnectionState) {
        switch (old, new) {
        case (.connected, .connected):
            return
        case (_, .connected):
            end()
        case (.connected, _):
            isActive = true
            let timer = DemandTimer(owner: "DaemonStore.dropGrace", clock: clock)
            self.timer?.cancel()
            self.timer = timer
            timer.schedule(after: duration) { @MainActor [weak self] in
                guard let self, self.timer === timer else { return }
                self.end()
            }
        default:
            return
        }
    }

    private func end() {
        timer?.cancel()
        timer = nil
        if isActive { isActive = false }
    }
}
