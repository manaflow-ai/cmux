import CmuxNextWakeups
import os

/// Says when a dead panel is dropped, so a picker that shows nothing has its reason in a bench's log.
private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "openPanel")

/// What ``MadeAheadOpenPanel`` does, over any panel type: a new panel for each request, and the process's first
/// panel paid ahead of the first click, while the person is idle. It keeps no panel. A live `NSOpenPanel` makes
/// its panel service (`com.apple.appkit.xpc.openAndSavePanelService`) keep the folder it shows in sync on each
/// file-system event (DesktopServicesPriv `TNode::SynchronizeChildren`): 2.8 to 4.8 % of a core for the life of
/// each app on a busy Mac (2026-11-10), so the panel kept for later clicks went away. The panel factory, the
/// warm-up check and the clock are injected, so a test drives it with stand-in panels and a manual clock, and
/// awaits each check on ``checksRan`` (`MadeAheadPanelStoreTests`).
@MainActor
final class MadeAheadPanelStore<Panel: OpenPanelLabels> {
    private let makePanel: @MainActor () -> Panel
    private let warmCheck: @MainActor () -> OpenPanelWarmCheck
    private let timer: DemandTimer
    /// A panel made here, held weakly: the store never keeps a panel alive.
    private struct Made {
        weak var panel: Panel?
    }
    /// One entry per panel made here that may still be alive. Entries of panels that went are removed at the next make.
    private var madePanels: [Made] = []

    /// Whether this process made a working panel, in the warm-up or for a request: its first-panel cost (the
    /// frameworks and the first answer of the panel service) is paid, and no other warm-up runs.
    private(set) var isWarm = false
    /// The panels made here that are still alive: one per picker on screen, and 0 at rest. The store holds none;
    /// a request's panel lives as long as its caller and its sheet keep it.
    var livePanels: Int { madePanels.count(where: { $0.panel != nil }) }
    /// Whether the last panel made came back dead (no prompt: its view service never answered). No warm-up runs
    /// again until a click makes a working panel: each `NSOpenPanel()` with no view service blocks the main
    /// thread about 40 s (no GUI session, 2026-10-23).
    private(set) var warmGaveUp = false
    /// The dead panels dropped so far.
    private(set) var droppedPanels = 0
    /// The warm-up checks run so far.
    private(set) var warmChecks = 0
    /// Whether a warm-up check is pending.
    var isWarming: Bool { timer.isScheduled }
    /// One element each time a warm-up check has run to its end (made a panel, rescheduled or gave up), so a test
    /// awaits the check instead of polling ``warmChecks``. Keeps only the newest element: nothing grows when no one
    /// listens.
    let checksRan: AsyncStream<Void>
    private let checkRan: AsyncStream<Void>.Continuation
    /// Whether the one notice for a warm-up that may never run (``OpenPanelWarmCheck/never(reason:)``) was logged.
    private var saidNever = false

    /// - Parameters:
    ///   - clock: The clock of the warm-up's checks; tests pass a manual clock.
    ///   - makePanel: Makes a new panel (`NSOpenPanel()`, 105 to 300 ms on the main thread).
    ///   - warmCheck: Whether a warm-up may make its panel now; read when a check fires.
    init(clock: any Clock<Duration> = ContinuousClock(), makePanel: @escaping @MainActor () -> Panel,
         warmCheck: @escaping @MainActor () -> OpenPanelWarmCheck) {
        self.makePanel = makePanel
        self.warmCheck = warmCheck
        timer = DemandTimer(owner: "openPanel.warm", clock: clock)
        let ran = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        checksRan = ran.stream
        checkRan = ran.continuation
    }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050 / #23233); the timer
    // cancels its own task when it goes.
    nonisolated deinit {}

    /// A new panel for this request; the caller owns it, and it goes when the caller's sheet ended. Nil when it
    /// came back dead (no prompt): it is not handed out, since a dead panel's sheet may never call its handler
    /// and a caller waiting on it would hang.
    func panel() -> Panel? {
        let panel = make()
        guard panel.openPanelPrompt != nil else {
            dropDead(onClick: true)
            return nil
        }
        isWarm = true
        warmGaveUp = false
        return panel
    }

    /// Pays the process's first panel once the person has paused: the first check 2 s from now, then one a second
    /// while busy, ten at most. Nothing in a warm process, and nothing after a dead panel (``warmGaveUp``).
    func warmWhenIdle() {
        guard !isWarm, !warmGaveUp, !timer.isScheduled else { return }
        check(after: .seconds(2), triesLeft: 10)
    }

    /// Makes one panel and lets it go at once: the process has then loaded what a panel needs, and no panel
    /// stays alive to keep its service at work. A panel whose view service never answered (no prompt) ends the
    /// warm-ups until a click makes a working one.
    private func warm() {
        let panel = make()
        guard panel.openPanelPrompt != nil else {
            dropDead(onClick: false)
            return
        }
        isWarm = true
    }

    /// A new panel, with its entry in ``livePanels``.
    private func make() -> Panel {
        madePanels.removeAll { $0.panel == nil }
        let panel = makePanel()
        madePanels.append(Made(panel: panel))
        return panel
    }

    /// Records a dead panel: no warm-up runs until a click makes a working one, and a notice says so.
    private func dropDead(onClick: Bool) {
        warmGaveUp = true
        droppedPanels += 1
        let dropped = droppedPanels
        let source = onClick ? "click (no picker shown)" : "warm-up"
        logger.notice(
            "open panel dropped from a \(source, privacy: .public) (no prompt, its view service never answered): \(dropped, privacy: .public) so far; no warm-up until a click makes a working panel"
        )
    }

    private func check(after delay: Duration, triesLeft: Int) {
        timer.schedule(after: delay) { @MainActor [weak self] in
            guard let self else { return }
            warmChecks += 1
            defer { checkRan.yield() }
            guard !isWarm, !warmGaveUp else { return }
            switch warmCheck() {
            case .never(let reason):
                // Once per store (the app has one): a test host or a fleet step without the console session would repeat it per view.
                if !saidNever {
                    saidNever = true
                    logger.notice("open panel warm-up off: \(reason, privacy: .public); the first click pays the first panel")
                }
            case .busy:
                if triesLeft > 1 { check(after: .seconds(1), triesLeft: triesLeft - 1) }
            case .ready:
                warm()
            }
        }
    }
}
