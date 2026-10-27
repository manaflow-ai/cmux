import CmuxNextCompat
import CmuxNextWakeups
import os

/// Says when a made-ahead panel is dropped, so a silent loss of the made-ahead path shows in a bench's log.
private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "openPanel")

/// What ``MadeAheadOpenPanel`` does, over any ``ReusableOpenPanel``: keep one panel made ahead of the click, hand
/// it out while it is free, and make it while the person is idle. Under
/// ``OpenPanelWarmPolicy/afterFirstUse(_:)`` it makes none before a click and releases the kept one
/// once it goes unused. The panel factory, the warm-up check, the clock and the release's planner are injected, so
/// a test drives it with stand-in panels and a manual clock, and awaits each check on ``checksRan``
/// (`MadeAheadPanelStoreTests`; the release on the App's overlay page planner in `MadeAheadPanelFirstUseTests`).
@MainActor
final class MadeAheadPanelStore<Panel: ReusableOpenPanel> {
    private let makePanel: @MainActor () -> Panel
    private let warmCheck: @MainActor () -> OpenPanelWarmCheck
    private let policy: OpenPanelWarmPolicy
    private let timer: DemandTimer
    /// Under ``OpenPanelWarmPolicy/afterFirstUse(_:)``, when the kept panel goes: a click is a show and its hide at
    /// once (the sheet's own use is checked at the release), and no warm-up runs before a click since the last
    /// release. Nil under ``OpenPanelWarmPolicy/ahead``.
    private var release: OverlayPageRelease?
    /// The panel made ahead and the texts it had when it was made (both or neither).
    private var made: (panel: Panel, defaults: OpenPanelDefaults)?

    /// Whether a panel was made ahead of a click.
    var isMade: Bool { made != nil }
    /// Whether the last panel made came back dead (no prompt: its view service never answered). No warm-up runs
    /// again until a click makes a working panel: each `NSOpenPanel()` with no view service blocks the main
    /// thread about 40 s (no GUI session, 2026-10-23).
    private(set) var warmGaveUp = false
    /// The dead panels dropped so far.
    private(set) var droppedPanels = 0
    /// The warm-up checks run so far.
    private(set) var warmChecks = 0
    /// The kept panels released after going unused so far.
    private(set) var releasedPanels = 0
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
    ///   - policy: When a panel is made and how long it is kept.
    ///   - makePanel: Makes a new panel (`NSOpenPanel()`, 105 to 300 ms on the main thread).
    ///   - warmCheck: Whether a warm-up may make the panel now; read when a check fires.
    init(clock: any Clock<Duration> = ContinuousClock(), policy: OpenPanelWarmPolicy = .ahead,
         makePanel: @escaping @MainActor () -> Panel, warmCheck: @escaping @MainActor () -> OpenPanelWarmCheck) {
        self.makePanel = makePanel
        self.warmCheck = warmCheck
        self.policy = policy
        // timer-class-allow: the warm-up's idle checks on the injected clock (the store's test seam): ten at most,
        // then none until a click; each runs only while the person is idle (OpenPanelWarmGate)
        timer = DemandTimer(owner: "openPanel.madeAhead.warm", clock: clock)
        let ran = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        checksRan = ran.stream
        checkRan = ran.continuation
        if case .afterFirstUse(let terms) = policy {
            release = terms.release(owner: "openPanel", inUse: { [weak self] in self?.isKeptPanelInUse ?? false }) { [weak self] in
                self?.dropKept()
            }
        }
    }

    /// Whether a warm-up may make a panel now under the policy.
    private var allowsWarmUp: Bool { policy.allowsWarmUp(usedSinceRelease: release?.allowsPrewarm ?? true) }

    // A generic main-actor class's isolated deinit crashes the Release optimizer (#23050 / #23233); the timer
    // cancels its own task when it goes.
    nonisolated deinit {}

    /// The panel made ahead when it is free, with a new panel's choices and texts, else a new one (kept when
    /// none is). Nil when the new one came back dead (no prompt): it is neither kept nor handed out, since a dead
    /// panel's sheet may never call its handler and a caller waiting on it would hang.
    func panel() -> Panel? {
        release?.didShow()
        defer { release?.didHide() }
        if let kept = made, kept.panel.isFreeForReuse {
            kept.panel.resetChoices()
            kept.defaults.apply(to: kept.panel)
            return kept.panel
        }
        let panel = makePanel()
        guard OpenPanelDefaults(of: panel) != nil else {
            dropDead(onClick: true)
            return nil
        }
        if made == nil { keep(panel) }
        return panel
    }

    /// Makes the panel once the person has paused: the first check 2 s from now, then one a second while busy,
    /// ten at most. Nothing after a dead panel (``warmGaveUp``), and nothing before a click under
    /// ``OpenPanelWarmPolicy/afterFirstUse(_:)``.
    func warmWhenIdle() {
        guard made == nil, !warmGaveUp, !timer.isScheduled, allowsWarmUp else { return }
        check(after: .seconds(2), triesLeft: 10)
    }

    /// Keeps `panel` for later clicks, unless its view service never answered (no prompt): then the warm-up
    /// gives up and the next click makes a new panel.
    private func keep(_ panel: Panel) {
        guard let defaults = OpenPanelDefaults(of: panel) else {
            dropDead(onClick: false)
            return
        }
        made = (panel, defaults)
        warmGaveUp = false
        release?.didMake()
    }

    /// Records a dead panel: no warm-up runs until a click makes a working one, and a notice says so.
    private func dropDead(onClick: Bool) {
        warmGaveUp = true
        droppedPanels += 1
        let dropped = droppedPanels
        let source = onClick ? "click (no picker shown)" : "warm-up"
        logger.notice(
            "made-ahead open panel dropped from a \(source, privacy: .public) (no prompt, its view service never answered): \(dropped, privacy: .public) so far; no warm-up until a click makes a working panel"
        )
    }

    private func check(after delay: Duration, triesLeft: Int) {
        timer.scheduleOnMain(after: delay) { [weak self] in
            guard let self else { return }
            warmChecks += 1
            defer { checkRan.yield() }
            guard made == nil, !warmGaveUp, allowsWarmUp else { return }
            switch warmCheck() {
            case .never(let reason):
                // Once per store (the app has one): a test host or a fleet step without the console session would repeat it per view.
                if !saidNever {
                    saidNever = true
                    logger.notice("open panel warm-up off: \(reason, privacy: .public); each click makes its panel")
                }
            case .busy:
                if triesLeft > 1 { check(after: .seconds(1), triesLeft: triesLeft - 1) }
            case .ready:
                keep(makePanel())
            }
        }
    }

    /// Whether a sheet or window shows the kept panel: the release keeps it, and the planner looks again one release
    /// time later (no event says the sheet ended).
    private var isKeptPanelInUse: Bool { made.map { !$0.panel.isFreeForReuse } ?? false }

    /// The release's call, made only while no sheet or window shows the kept panel: drops it, so its panel service
    /// can exit. A pending warm-up ends too: the next waits for a click.
    private func dropKept() {
        made = nil
        timer.cancel()
        releasedPanels += 1
        let released = releasedPanels
        logger.debug("made-ahead open panel released after going unused (\(released, privacy: .public) so far)")
    }
}
