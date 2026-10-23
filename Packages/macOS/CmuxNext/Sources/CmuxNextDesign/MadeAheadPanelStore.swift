import CmuxNextWakeups

/// What ``MadeAheadOpenPanel`` does, over any ``ReusableOpenPanel``: keep one panel made ahead of the click, hand
/// it out while it is free, and make it while the person is idle. The panel factory, the warm-up check and the
/// clock are injected, so a test drives it with stand-in panels and a manual clock (`MadeAheadPanelStoreTests`).
@MainActor
final class MadeAheadPanelStore<Panel: ReusableOpenPanel> {
    private let makePanel: @MainActor () -> Panel
    private let warmCheck: @MainActor () -> OpenPanelWarmCheck
    private let timer: DemandTimer
    /// The panel made ahead and the texts it had when it was made (both or neither).
    private var made: (panel: Panel, defaults: OpenPanelDefaults)?

    /// Whether a panel was made ahead of a click.
    var isMade: Bool { made != nil }
    /// The warm-up checks run so far.
    private(set) var warmChecks = 0
    /// Whether a warm-up check is pending.
    var isWarming: Bool { timer.isScheduled }

    /// - Parameters:
    ///   - clock: The clock of the warm-up's checks; tests pass a manual clock.
    ///   - makePanel: Makes a new panel (`NSOpenPanel()`, 105 to 300 ms on the main thread).
    ///   - warmCheck: Whether a warm-up may make the panel now; read when a check fires.
    init(clock: any Clock<Duration> = ContinuousClock(), makePanel: @escaping @MainActor () -> Panel,
         warmCheck: @escaping @MainActor () -> OpenPanelWarmCheck) {
        self.makePanel = makePanel
        self.warmCheck = warmCheck
        timer = DemandTimer(owner: "openPanel.madeAhead.warm", clock: clock)
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050 / #23233); the timer
    // cancels its own task when it goes.
    nonisolated deinit {}

    /// The panel made ahead when it is free, with a new panel's choices and texts, else a new one (kept when
    /// none is).
    func panel() -> Panel {
        if let kept = made, kept.panel.isFreeForReuse {
            kept.panel.resetChoices()
            kept.defaults.apply(to: kept.panel)
            return kept.panel
        }
        let panel = makePanel()
        if made == nil { keep(panel) }
        return panel
    }

    /// Makes the panel once the person has paused: the first check 2 s from now, then one a second while busy,
    /// ten at most.
    func warmWhenIdle() {
        guard made == nil, !timer.isScheduled else { return }
        check(after: .seconds(2), triesLeft: 10)
    }

    /// Keeps `panel` for later clicks, unless its view service never answered (no prompt).
    private func keep(_ panel: Panel) {
        guard let defaults = OpenPanelDefaults(of: panel) else { return }
        made = (panel, defaults)
    }

    private func check(after delay: Duration, triesLeft: Int) {
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self else { return }
            warmChecks += 1
            guard made == nil else { return }
            switch warmCheck() {
            case .never:
                return
            case .busy:
                if triesLeft > 1 { check(after: .seconds(1), triesLeft: triesLeft - 1) }
            case .ready:
                keep(makePanel())
            }
        }
    }
}
