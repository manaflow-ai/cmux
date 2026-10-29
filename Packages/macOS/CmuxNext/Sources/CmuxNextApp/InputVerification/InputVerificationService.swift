import AppKit
import CmuxNextCompat
import CmuxNextControl
import CmuxNextFocus
import CmuxNextInput
import CmuxNextInputModel
import CmuxNextInvariants
import CmuxNextSettings
import CmuxNextWakeups
import os

/// Input verification (plans/cmux-next/input-spec.md): the journal policy,
/// the input tap's events into the journal, the invariant registry and the
/// signals that touch it (plans/cmux-next/invariants-DESIGN.md), the windows'
/// focus journaling, and in no-activate mode the keyboard guard
/// (`InputVerificationService+NoActivateGuard.swift`). One per app, owned by
/// `AppServices.input`; observers live as long as the app.
final class InputVerificationService {
    #if DEBUG || CMUX_BENCH_HOOKS
    /// The app's one invariant registry (Debug and bench builds), made with its rules in `AppServices.init`
    /// (`makeInvariants`), so `debug.invariants` answers from the first request; `start` wires its signals.
    private(set) var invariants: InvariantRegistry?
    /// Runs the registry at the end of every committed turn; only while the registry is armed.
    private var turnObserver: InvariantTurnObserver?
    /// Writes the violations' reports, off the violating turn.
    private var reporter: InvariantReporter?
    /// Each window's observation as the last pass built it, taken again by a pass that touched nothing it reads.
    private let observed = InputObservationReuse()
    #endif
    /// The journal of the latest violation's report, for `debug.replay {source: "report"}` (nil before one).
    private(set) var lastReportJournal: [InputJournalEntry]?
    /// `start` ran.
    private(set) var isStarted = false
    /// Any window's move, resize, screen and deminiaturize notices (`observeWindowGeometry`).
    private var geometrySubscriptions: [EventSubscription] = []
    /// Any window's occlusion notice (`observeWindowOcclusion`).
    private var occlusionObserver: MainNotificationObserver?
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

    /// Journal entries a violation's report keeps.
    static let reportJournalTail = 512
    /// Tab switch timeline marks (category "tab-switch", debug level).
    nonisolated static let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")

    /// The probe producers touch the invariant registry through (an empty value in Release).
    var probe: InvariantProbe {
        #if DEBUG || CMUX_BENCH_HOOKS
        InvariantProbe(registry: invariants)
        #else
        InvariantProbe()
        #endif
    }

    /// Configures the journal, subscribes it to the input tap and, in Debug and bench builds, wires the invariant
    /// registry's signals and its turn observer (the `InputVerification.start` launch post).
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
        // A press touches the focus rules of the window that has the keys.
        let notePress: (@MainActor () -> Void)? = { [weak self] in self?.touchKeyWindow() }
        #else
        let notePress: (@MainActor () -> Void)? = nil
        #endif
        journalSubscription = Self.subscribeJournal(journal, to: services.inputTap, notePress: notePress)
        observeWindowGeometry(services.appEvents, journal: journal)
    }

    /// Makes the invariant registry and declares every rule the app holds (`AppServices.init`, the composition root):
    /// it exists before any launch post, so `debug.invariants` answers `armed` from the first request and a check on
    /// demand runs every rule. Pure wiring: no signal, no observer and no run-loop work until `start`. Release has
    /// no checker: nothing.
    func makeInvariants(services: AppServices) {
        #if DEBUG || CMUX_BENCH_HOOKS
        makeRegistry(services: services)
        #endif
    }

    /// Records each key, flags, button, drag and scroll event from `tap` into `journal` before the key
    /// router (pointer moves carry no focus), and calls `notePress` on a press or a left mouse-up (Debug and bench
    /// builds: it touches the focus rules; Release passes none).
    static func subscribeJournal(_ journal: InputJournal, to tap: InputEventTap,
                                 notePress: (@MainActor () -> Void)?) -> InputSubscription {
        tap.subscribe(class: [.key, .flags, .button, .drag, .scroll]) { event in
            journal.record(event)
            guard let notePress else { return }
            switch event.type {
            case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp: notePress()
            default: break
            }
        }
    }

    /// Any window's occlusion changed (the `SurfaceInvariant.observeWindowOcclusion` launch post): the tab-switch
    /// timeline marks when a page child window's occlusion lands, and in Debug and bench builds the blank-pane rule
    /// (VS2) looks at that window's panes again (panes of an occluded window draw nothing by design and are not
    /// judged; the check after the window is visible again proves every surface drew).
    func observeWindowOcclusion(services: AppServices) {
        guard occlusionObserver == nil else { return }
        // In the notice's delivery (a frame-class handler runs there), so the timeline mark is when the state landed.
        occlusionObserver = MainNotificationObserver(NSWindow.didChangeOcclusionStateNotification, class: .frame,
                                                     owner: "InputVerification.windowOcclusion", on: services.mainWork,
                                                     read: { $0.object as? NSWindow }) { [weak self, weak services] window in
            guard let window else { return }
            #if DEBUG || CMUX_BENCH_HOOKS
            // A touch only marks the window's panes for this turn's check.
            if let owner = services?.windows.owner(of: window) { self?.probe.touch(.visibility, .window(owner.state.id)) }
            #else
            _ = (self, services)
            #endif
            // Tab switch timeline (cx-asb1): when a page child window's occlusion state lands.
            let child = window.parent != nil
            let visible = window.occlusionState.contains(.visible)
            // wall-clock: one timeline with the Control and Browser tab-switch marks and the page's performance.timeOrigin
            Self.tabSwitchLog.debug("tab-switch occlusion-\(child ? "child" : "top", privacy: .public)-\(visible ? "visible" : "hidden", privacy: .public)-\(String(describing: type(of: window)).filter(\.isLetter), privacy: .public)\(window.identifier?.rawValue.filter(\.isLetter) ?? "", privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
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
            let moved = self?.journalMovedWindows(journal) ?? []
            #if DEBUG || CMUX_BENCH_HOOKS
            // The frame rules of each cmux window that moved; a page window that moved alone is G1's, a harness rule.
            for window in moved { self?.probe.touch(.paneFrame, .window(window)) }
            #else
            _ = moved
            #endif
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

    /// Journals the frame of each cmux window whose frame differs from the one last journaled; returns their ids.
    private func journalMovedWindows(_ journal: InputJournal) -> [String] {
        guard let controllers = services?.windows.controllers else { return [] }
        var frames: [ObjectIdentifier: NSRect] = [:]
        var moved: [String] = []
        for controller in controllers {
            guard let window = controller.window else { continue }
            let frame = window.frame, key = ObjectIdentifier(window)
            frames[key] = frame
            guard journaledFrames[key] != frame else { continue }
            moved.append(controller.state.id)
            journal.appendWindowFrame(window: controller.state.id, (frame.minX, frame.minY, frame.width, frame.height))
        }
        journaledFrames = frames
        return moved
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
    /// Makes the registry and declares every rule the app holds (``makeInvariants(services:)``).
    private func makeRegistry(services: AppServices) {
        guard invariants == nil else { return }
        self.services = services
        let mode = InvariantMode(environment: ProcessInfo.processInfo.environment)
        // The liveness rules' one deadline: a background-class task nobody watches (a debug check).
        let deadline = MainDeadline(owner: "InvariantRegistry.liveness", workClass: .background, scheduler: services.mainDeadlines)
        let registry = InvariantRegistry(mode: mode) { delay, work in deadline.schedule(after: delay, work) }
        invariants = registry
        let reporter = makeReporter(registry, services: services)
        self.reporter = reporter
        registry.onReports = { [weak reporter] in reporter?.take($0) }
        // The input rules over one world check per pass; W11 over the same observation.
        let world: @MainActor (InvariantPass) -> InputInvariants.WorldResult? = { [weak self, weak services] pass in
            guard let self, let services else { return nil }
            return pass.memo("input.world") {
                let observed = observation(in: pass, services: services)
                var result = InputInvariants.world(observed)
                result.observation = observed
                return result
            }
        }
        for rule in InputInvariants.declaredRules(world: world) { registry.declare(rule) }
        registry.declare(InputInvariants.expectationRule { [weak services] pass in
            guard let services, let observation = world(pass)?.observation else { return nil }
            return (observation.windows, Self.holdingWindows(services))
        })
        ChildPageGeometry.declareInvariants(in: registry, services: services)
        DebugTabDrag.declareInvariants(in: registry, services: services)
        SurfaceDiagnosticsReport.declareInvariants(in: registry, services: services)
        WindowInvariants.declareInvariants(in: registry, services: services)
        services.hoverCards.declareInvariants(in: registry)
    }

    /// Feeds the registry the action, presentation, mirror and hover signals and, when armed (`CMUX_NEXT_INVARIANTS`),
    /// checks it at the end of every committed turn, inside the turn meter's debug-check span (the
    /// `InputVerification.start` launch post).
    private func startInvariants(services: AppServices) {
        guard let registry = invariants else { return }
        services.hoverCards.invariants = probe
        services.machines.invariants = probe
        // A violation names the actions of its turn; no string is built per action.
        services.registry.willRunObservers.append { [weak registry] id, origin in registry?.noteAction(id.rawValue, origin: origin.rawValue) }
        services.cache.presentationChanges.subscribe("invariants") { [weak self] in self?.touchPresentation() }
        guard registry.isArmed, turnObserver == nil else { return }
        let turns = services.mainWork.budget.turns
        turnObserver = InvariantTurnObserver(registry: registry) { [weak turns] pass in
            if let turns { turns.debugCheck(pass) } else { pass() }
        }
    }

    /// The registry's reports: journaled at once; the journal tail, the observation, `debug.focus`,
    /// `debug.surfaces` and `debug.layers` read once per report in a background turn after the frame.
    private func makeReporter(_ registry: InvariantRegistry, services: AppServices) -> InvariantReporter {
        let journal = InputJournal.shared
        let delivery = MainDelivery(class: .background, owner: "InvariantReports.written", on: services.mainWork)
        return InvariantReporter(
            registry: registry, store: InvariantReportStore(tag: services.environment.tag, runner: services.work),
            post: { [weak services] work in services?.mainWork.post(.background, owner: "InvariantReports.capture", work) },
            deliver: { work in delivery.run(work) },
            journal: { batch in
                journal.append(window: batch.first?.subject.windowID, .desync(batch.map { "\($0.id.rawValue) \($0.subject): \($0.detail)" }))
                return journal.stats.lastSeq
            },
            capture: { [weak self, weak services] in
                guard let services else { return [:] }
                let entries = journal.entries(last: Self.reportJournalTail)
                self?.lastReportJournal = entries
                let stats = journal.stats, observation = InputObservationBuilder.observe(services)
                let facets: [String: CmuxNextSettings.JSONValue] = [
                    "debug_focus": DebugFocus.report(services: services), "debug_surfaces": SurfaceDiagnosticsReport.make(services),
                    "debug_layers": DebugLayers.report(services: services), "tag": services.environment.tag.map { .string($0) } ?? .null,
                ]
                var facts: InvariantReporter.Facts = facets.mapValues { facet -> @Sendable () -> Data in { Data(facet.prettyText().utf8) } }
                facts["observation"] = { Data(AppControl.encode(observation).prettyText().utf8) }
                facts["journal"] = { Data(AppControl.encode(entries).prettyText().utf8) }
                facts["journal_stats"] = { Data(AppControl.encode(stats).prettyText().utf8) }
                return facts
            })
    }

    /// A press: the focus rules of the window that has the keys (its own, or the one that owns its page, panel or
    /// sheet) run at this turn's commit; a press with no cmux window to name touches every window.
    private func touchKeyWindow() {
        guard let registry = invariants, registry.isArmed else { return }
        let owner = NSApp.keyWindow.flatMap { services?.windows.owner(of: $0) }
        registry.touch(.focus, owner.map { .window($0.state.id) } ?? .app)
    }

    /// A presentation change: the panes that now present a changed tab, and their windows. A changed tab no pane
    /// presents any more (a pane left empty) names no window, so every window counts then.
    private func touchPresentation() {
        guard let registry = invariants, registry.isArmed, let services else { return }
        guard let keys = services.cache.presentationChanges.changedKeys else { return registry.touch(.presentation, .app) }
        var found = Set<String>()
        for controller in services.windows.controllers {
            for pane in controller.content?.panes.values.map({ $0 }) ?? [] {
                guard let key = pane.currentTabKey, keys.contains(key) else { continue }
                found.insert(key)
                registry.touch(.presentation, .pane(pane.paneKey))
                registry.touch(.presentation, .window(controller.state.id))
            }
        }
        if found.count < keys.count { registry.touch(.presentation, .app) }
    }

    /// The observation of this pass, built once: a window no key it reads was touched for keeps the observation the
    /// last pass built; the windows a turn touched, the key window and the active one are read again.
    private func observation(in pass: InvariantPass, services: AppServices) -> InputObservation {
        pass.memo("input.observation") {
            let windows = services.windows
            let dirty = pass.touchedSubjects([.focus, .presentation, .paneFrame]).map { subjects in
                Set(subjects.compactMap { subject -> String? in
                    guard case .pane(let key) = subject else { return subject.windowID }
                    return windows.controllers.first { $0.content?.panes.values.contains { $0.paneKey == key } == true }?.state.id
                })
            }
            let pinned = Set([windows.active?.state.id, NSApp.keyWindow.flatMap { windows.owner(of: $0)?.state.id }].compactMap { $0 })
            let observation = InputObservationBuilder.observe(services) { [observed] in observed.window($0.state.id, dirty: dirty, pinned: pinned) }
            observed.keep(observation)
            return observation
        }
    }

    /// The windows whose keys wait in a creation or New Tab hold now: W11's clock starts when the hold ends.
    static func holdingWindows(_ services: AppServices) -> Set<String> {
        let router = services.keyRouter
        return Set(services.windows.controllers.filter {
            router.creationInputCoordinator.isHolding(in: $0.window) || router.newTabInputCoordinator.isHolding(in: $0.window)
        }.map(\.state.id))
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
