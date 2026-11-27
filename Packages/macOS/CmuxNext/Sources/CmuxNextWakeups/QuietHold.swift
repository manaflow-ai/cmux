/// Holds back a state that usually ends on its own (a link reconnecting) until it has lasted `delay`, then lets it
/// show once (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up"). One stretch of the state
/// is one hold: asking again while it lasts neither restarts the wait nor hides it again once shown; any other state
/// ends the stretch. One ``DemandTimer`` per stretch; nothing runs at idle.
@MainActor
public final class QuietHold {
    /// The one quiet time of a connection state that usually heals on its own ("Connecting…", "Reconnecting…",
    /// "Disconnected" over the last frame): the daemon's startup deadline and its drop grace. A phone blip, a
    /// foreground reattach and a daemon handoff after an update (about 10 s) heal under it. Every connection
    /// label waits this long, through this constant, instead of picking its own time.
    nonisolated public static let connectionDelay: Duration = .seconds(10)
    /// ``connectionDelay`` in seconds, for the waits that take a `TimeInterval`.
    nonisolated public static let connectionDelaySeconds = Double(connectionDelay.components.seconds)
    /// The quiet time of something coming up for the first time that has its own way out (a connecting card with
    /// Cancel, a new pane's "Starting…"): most connects land under it, so a fast one draws no label at all. The same
    /// second as the terminal's `TerminalStatusBanner.startingRevealDelay` and Screen Sharing's connect notice.
    nonisolated public static let comingUpDelay: Duration = .seconds(1)

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
