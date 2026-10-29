import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextFocus
import CmuxNextInput
import CmuxNextInputModel
import CmuxNextInvariants
import CmuxNextSettings
import CmuxNextWakeups

/// Input verification (plans/cmux-next/input-spec.md): the journal policy,
/// the input tap's events into the journal, the invariant registry and the
/// signals that touch it (plans/cmux-next/invariants-DESIGN.md), the windows'
/// focus journaling, and in no-activate mode the keyboard guard
/// (`InputVerificationService+NoActivateGuard.swift`). One per app, owned by
/// `AppServices.input`; observers live as long as the app.
final class InputVerificationService {
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The app's one invariant registry (Debug and bench builds); set by `start` (nil before it).
    private(set) var invariants: InvariantRegistry?
    /// Runs the registry at the end of every committed turn; only while the registry is armed.
    private var turnObserver: InvariantTurnObserver?
    /// Where the violations' reports go.
    private var reports: InvariantReportStore?
    /// W11's clock per window (`FocusExpectationAges`): one expectation keeps its clock across a re-key.
    private var expectations = FocusExpectationAges()
    #endif
    /// The journal of the latest violation's report, for `debug.replay {source: "report"}` (nil before one).
    private(set) var lastReportJournal: [InputJournalEntry]?
    /// `start` ran.
    private(set) var isStarted = false
    /// Any window's move, resize, screen and deminiaturize notices (`observeWindowGeometry`).
    private var geometrySubscriptions: [EventSubscription] = []
    /// Each cmux window's frame as last journaled, so a notice journals only the windows that moved.
    private var journaledFrames: [ObjectIdentifier: NSRect] = [:]
    /// No-activate mode only: gives back a keyboard the user did not give.
    var keyboardGuard: NoActivateKeyboardGuard?
    /// No-activate mode only: the guard's activation and key-window subscriptions.
    var keyboardGuardSubscriptions: [EventSubscription] = []
    /// No-activate mode only: another app's activation, with the app the notice names.
    var keyboardGuardActivation: MainActorObservation?
    /// The journal's subscription to the input tap (before the key router), which also touches the focus rules.
    private var journalSubscription: InputSubscription?
    /// No-activate mode only: the keyboard guard's subscription to the person's key and mouse presses.
    var keyboardGuardSubscription: InputSubscription?
    private weak var services: AppServices?

    /// How long a focus expectation may wait to land (W11): the creation hold (`CreationInputCoordinator.holdLimit`,
    /// 2 s), the longest the keys typed meanwhile are held for it, plus W9's wait for the presentation.
    static let expectationLimit: Duration = .seconds(2) + presentationLimit
    /// How long a window's focused pane may present another tab than the one the model targets (W9): about 12
    /// display frames.
    static let presentationLimit: Duration = .milliseconds(200)
    /// Journal entries a violation's report keeps.
    static let reportJournalTail = 512

    /// The probe producers touch the invariant registry through (an empty value in Release).
    var probe: InvariantProbe {
        #if DEBUG || CMUX_BENCH_HOOKS
        InvariantProbe(registry: invariants)
        #else
        InvariantProbe()
        #endif
    }

    /// Configures the journal, subscribes it to the input tap and, in Debug and bench builds, starts the invariant
    /// registry and its signals (the `InputVerification.start` launch post).
    /// The no-activate keyboard guard is an NSApp input hook: `AppServices.init`
    /// installs it (`startNoActivateGuard(tap:appEvents:mainWork:work:)`), before the app activates.
    func start(services: AppServices) {
        self.services = services
        isStarted = true
        let journal = InputJournal.shared
        let tag = services.environment.tag
        journal.configure(InputJournalPolicy.resolve(isDebugBuild: ControlService.isDebugBuild, tag: tag,
                                                     environment: ProcessInfo.processInfo.environment))
        #if DEBUG || CMUX_BENCH_HOOKS
        startInvariants(services: services)
        #endif
        journalSubscription = Self.subscribeJournal(journal, to: services.inputTap) { [weak self] in self?.probe.touch(.focus, .app) }
        observeWindowGeometry(services.appEvents, journal: journal)
    }

    /// Records each key, flags, button, drag and scroll event from `tap` into `journal` before the key
    /// router (pointer moves carry no focus), and calls `notePress` on a press or a left mouse-up (it touches the
    /// focus rules).
    static func subscribeJournal(_ journal: InputJournal, to tap: InputEventTap,
                                 notePress: @escaping @MainActor () -> Void) -> InputSubscription {
        tap.subscribe(class: [.key, .flags, .button, .drag, .scroll]) { event in
            journal.record(event)
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp: notePress()
            default: break
            }
        }
    }

    /// A window moved or resized by any source (a drag, an Accessibility
    /// client such as Rectangle, a display or Space change): journal the
    /// frame of each cmux window that moved and touch the frame rules (G1, the
    /// Chromium page geometry). A page window that moved on its own (an AX
    /// client that got the page window) is checked too: any window's notice
    /// touches them. The app's one observer per notice (`AppServices.appEvents`);
    /// the subscriptions live as long as the app.
    private func observeWindowGeometry(_ events: AppEvents, journal: InputJournal) {
        let changed: @MainActor () -> Void = { [weak self] in
            self?.journalMovedWindows(journal)
            self?.probe.touch(.paneFrame, .app)
        }
        let owner = "InputVerification.windowGeometry"
        geometrySubscriptions = [
            events.subscribe(NSWindow.didMoveNotification, owner: owner, changed),
            events.subscribe(NSWindow.didResizeNotification, owner: owner, changed),
            events.subscribe(NSWindow.didEndLiveResizeNotification, owner: owner, changed),
            events.subscribe(NSWindow.didChangeScreenNotification, owner: owner, changed),
            events.subscribe(NSWindow.didDeminiaturizeNotification, owner: owner, changed),
        ]
    }

    /// Journals the frame of each cmux window whose frame differs from the one last journaled.
    private func journalMovedWindows(_ journal: InputJournal) {
        guard let controllers = services?.windows.controllers else { return }
        var frames: [ObjectIdentifier: NSRect] = [:]
        for controller in controllers {
            guard let window = controller.window else { continue }
            let frame = window.frame, key = ObjectIdentifier(window)
            frames[key] = frame
            guard journaledFrames[key] != frame else { continue }
            journal.appendWindowFrame(window: controller.state.id, (frame.minX, frame.minY, frame.width, frame.height))
        }
        journaledFrames = frames
    }

    /// Journals `controller`'s focus transitions (with a checkpoint every
    /// `checkpointInterval` transitions, so replay can start mid-ring) and
    /// touches the focus rules for its window.
    func observeFocus(of controller: WindowController) {
        let journal = InputJournal.shared
        // `services` and the registry are read when an observer runs, never captured here: the launch window installs
        // its observers before the `InputVerification.start` post (afterFirstFrame) sets them, and a nil captured
        // then dropped that window's checks for the whole session.
        var sinceCheckpoint = Int.max - 1
        // The notification and location-trail observers act on the settled
        // keyboard target: each runs only when what it reads changed. The
        // trail also reads the active window, a shown top page and the
        // selected workspace (a settle it skipped under a top page records
        // once the page hides).
        var notified: FocusState.SettleKey?
        var trailed: TrailSettleKey?
        controller.focus.settledObserver = { [weak self, weak controller] state in
            let services = self?.services
            services?.keyRouter.focusDidSettle(state, in: controller?.window)
            guard let controller else { return }
            // Chips shown for a held modifier follow the new focus (pane navigation while held).
            controller.shortcutHints?.focusDidSettle()
            services?.windows.recordSaver.focusDidSettle(controller.state, pane: state.pane)
            let key = state.settleKey
            if key != notified {
                notified = key
                services?.notifications.focusDidSettle(state, in: controller)
                // What new terminals and chats copy (NEW-WORK-INHERITS-CONTEXT).
                services?.noteWorkFocus(state, in: controller)
            }
            let trail = TrailSettleKey(focus: key, active: services?.windows.active === controller,
                                       topPage: controller.shownTopPage != nil, workspace: controller.state.workspaceID)
            if trail != trailed {
                trailed = trail
                services?.locationTrail.focusDidSettle(state, in: controller)
            }
        }
        controller.focus.observer = { [weak self, weak state = controller.state, weak focus = controller.focus] observation in
            let window = state?.id
            // A no-op reduction (a responder report of the focus the window
            // already has) changes nothing the focus rules read.
            if case .reduced(_, _, _, false) = observation {} else { self?.probe.touch(.focus, window.map(InvariantSubject.window) ?? .app) }
            guard journal.isEnabled else { return }
            switch observation {
            case .reduced(let event, _, let next, _):
                journal.append(window: window, .focus(event, after: FocusDigest(next)))
                sinceCheckpoint += 1
                // The state after this event (the machine holds only the
                // current one): replay starts from it with the next event.
                if sinceCheckpoint >= InputJournal.checkpointInterval, let focus {
                    sinceCheckpoint = 0
                    journal.append(window: window, .focusCheckpoint(focus.checkpoint()))
                }
            case .suppressedResponder(let responder):
                journal.append(window: window, .responder(responder, suppressed: true))
            case .refusedByRun:
                // Nothing changed: the run had no view-change permission.
                break
            }
        }
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension InputVerificationService {
    /// Makes the registry, declares every rule the app holds, feeds it the action, presentation, mirror and hover
    /// signals, and, when armed (`CMUX_NEXT_INVARIANTS`), checks it at the end of every committed turn.
    private func startInvariants(services: AppServices) {
        let mode = InvariantMode(environment: ProcessInfo.processInfo.environment)
        // The liveness rules' one deadline: a background-class task nobody watches (a debug check).
        let deadline = MainDeadline(owner: "InvariantRegistry.liveness", workClass: .background, scheduler: services.mainDeadlines)
        let registry = InvariantRegistry(mode: mode) { delay, work in deadline.schedule(after: delay, work) }
        invariants = registry
        reports = InvariantReportStore(tag: services.environment.tag, runner: services.work)
        registry.onReport = { [weak self] violation, state in self?.reported(violation, state: state) }
        declareInvariants(in: registry, services: services)
        ChildPageGeometry.declareInvariants(in: registry, services: services)
        DebugTabDrag.declareInvariants(in: registry, services: services)
        services.hoverCards.declareInvariants(in: registry)
        services.hoverCards.invariants = probe
        services.machines.invariants = probe
        // A violation names the actions of its turn; no string is built per action.
        services.registry.willRunObservers.append { [weak registry] id, origin in registry?.noteAction(id.rawValue, origin: origin.rawValue) }
        services.cache.presentationChanges.subscribe("invariants") { [weak registry] in registry?.touch(.presentation, .app) }
        if mode.isArmed { turnObserver = InvariantTurnObserver(registry: registry) }
    }

    /// The input rules (plans/cmux-next/input-spec.md 2.5, focus-invariant.md): F1-F8, W1-W8 and W10 on one
    /// observation per pass, and the liveness rules W9 (the focused pane presents the targeted tab) and W11 (a focus
    /// expectation lands). The observation names windows and panes, so none of them is a parity rule.
    func declareInvariants(in registry: InvariantRegistry, services: AppServices) {
        let observe: @MainActor (InvariantPass) -> InputObservation? = { [weak services] pass in
            services.map { services in pass.memo("input.observation") { InputObservationBuilder.observe(services) } }
        }
        for invariant in InputInvariants.worldRules {
            let chromium = invariant == .chromiumMatches
            registry.declare(InvariantRule(
                id: InvariantID(rawValue: invariant.rawValue), statement: invariant.summary, owner: "InputVerification",
                reads: [.focus, .presentation, .paneFrame], points: [.afterAction, .afterTurn], cost: .walk, parity: false,
                interim: chromium ? "confirms at the next check point until the Chromium focus in-flight ledger exists" : nil,
                confirmsAtNextCheck: chromium, read: observe,
                check: { observation in InputInvariants.violations(of: invariant, in: observation).map(Self.finding) }))
        }
        registry.declare(.liveness(
            id: InvariantID(rawValue: InputInvariant.presentationSettles.rawValue), statement: InputInvariant.presentationSettles.summary,
            owner: "InputVerification", reads: [.focus, .presentation], limit: Self.presentationLimit) { pass in
                guard let observation = observe(pass) else { return [] }
                return InputInvariants.unsettledWindows(observation).map {
                    InvariantPending(subject: .window($0), detail: "the focused pane does not present the targeted tab")
                }
            })
        registry.declare(.liveness(
            id: InvariantID(rawValue: InputInvariant.expectationLands.rawValue), statement: InputInvariant.expectationLands.summary,
            owner: "InputVerification", reads: [.focus, .presentation], limit: Self.expectationLimit) { [weak self, weak services] pass in
                guard let self, let services, let observation = observe(pass) else { return [] }
                return expectations.pending(observation.windows, now: pass.now, holding: Self.holdingWindows(services)).map {
                    InvariantPending(subject: .window($0.window), since: $0.since, detail: $0.detail)
                }
            })
    }

    /// The windows whose keys wait in a creation or New Tab hold now: W11's clock starts when the hold ends.
    static func holdingWindows(_ services: AppServices) -> Set<String> {
        let router = services.keyRouter
        return Set(services.windows.controllers.filter {
            router.creationInputCoordinator.isHolding(in: $0.window) || router.newTabInputCoordinator.isHolding(in: $0.window)
        }.map(\.state.id))
    }

    nonisolated static func finding(_ violation: InputViolation) -> InvariantFinding {
        InvariantFinding(subject: violation.window.map(InvariantSubject.window) ?? .app, detail: violation.detail)
    }

    /// A new violation (the registry's `onReport`): journaled now; its report (the rule's state, the journal tail,
    /// the observation, `debug.focus`, `debug.surfaces` and `debug.layers`) is read after this frame, not in the
    /// violating turn, and encoded and written on the files lane.
    private func reported(_ violation: InvariantViolation, state: Data?) {
        guard let services, let reports else { return }
        let journal = InputJournal.shared
        journal.append(window: violation.subject.windowID, .desync(["\(violation.id.rawValue) \(violation.detail)"]))
        let url = reports.url(for: violation)
        invariants?.ledger.annotate(violation.seq, journalTail: journal.stats.lastSeq, report: url?.path(percentEncoded: false))
        let tag = services.environment.tag
        AfterFrameCommit().run { [weak self, weak services] in
            guard let self, let services else { return }
            let entries = journal.entries(last: Self.reportJournalTail)
            lastReportJournal = entries
            let stats = journal.stats, observation = InputObservationBuilder.observe(services)
            let read: [String: CmuxNextSettings.JSONValue] = [
                "violation": InvariantsControl.json(violation),
                "debug_focus": DebugFocus.report(services: services),
                "debug_surfaces": SurfaceDiagnosticsReport.make(services),
                "debug_layers": DebugLayers.report(services: services),
            ]
            reports.write(for: violation) {
                var fields = read
                fields["tag"] = tag.map(CmuxNextSettings.JSONValue.string) ?? .null
                fields["created_at"] = .string(Date().formatted(.iso8601))
                fields["state"] = state.flatMap { try? CmuxNextSettings.JSONValue.parse($0) } ?? .null
                fields["observation"] = AppControl.encode(observation)
                fields["journal"] = AppControl.encode(entries)
                fields["journal_stats"] = AppControl.encode(stats)
                return Data(CmuxNextSettings.JSONValue.object(fields).prettyText().utf8)
            }
        }
    }
}
#endif

/// What `LocationTrailService.focusDidSettle` reads: the focus and the
/// window facts it skips on.
private struct TrailSettleKey: Hashable {
    var focus: FocusState.SettleKey
    var active: Bool
    var topPage: Bool
    var workspace: String?
}
