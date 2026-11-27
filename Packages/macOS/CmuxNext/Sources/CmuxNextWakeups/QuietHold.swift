/// Holds back a state that usually ends on its own (a link reconnecting) until it has lasted `delay`, then lets it
/// show once (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up"). One stretch of the state
/// is one hold: asking again while it lasts neither restarts the wait nor hides it again once shown; any other state
/// ends the stretch. One ``DemandTimer`` per stretch; nothing runs at idle.
@MainActor
public final class QuietHold {
    /// The state is on and younger than `delay`: draw nothing for it yet.
    public private(set) var held = false
    private var shown = false
    private let delay: Duration
    private let timer: DemandTimer

    public init(owner: String, delay: Duration, clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        timer = DemandTimer(owner: owner, clock: clock)
    }

    /// `active`: the state is on now. `onShow` runs once the state has lasted `delay`, after `held` turns false.
    public func update(_ active: Bool, onShow: @escaping @MainActor () -> Void) {
        guard active else {
            timer.cancel()
            (held, shown) = (false, false)
            return
        }
        guard !held, !shown else { return }
        held = true
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self, held else { return }
            (held, shown) = (false, true)
            onShow()
        }
    }
}
