import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextFocus
import CmuxNextSignposts

/// Applies reducer effects to the real world (AppKit, WebKit, CEF, layout,
/// registry context). `FocusEffectApplier` in the app; a recorder in tests.
protocol FocusEffectApplying: AnyObject {
    func apply(_ effects: [FocusEffect], state: FocusState)
}

/// The focus state machine of one window (plans/cmux-next/focus.md).
///
/// Events are reduced in FIFO order. Effects run after the reducer
/// returns; events raised while they run (responder reports, selection
/// echoes) are queued and reduced afterwards, so the reducer is never
/// re-entered. While effects run, `isApplying` is true and responder
/// reports caused by the applier's own `makeFirstResponder` are dropped.
final class FocusCoordinator {
    /// The read view of the machine's state (refreshed from each reply). A pure read: a pending
    /// topology (`setNeedsTopology`) is reduced before the next event, at the end of the turn, or
    /// by `currentState()`, never inside a read (a read can sit inside an AppKit responder change).
    var state: FocusState { reduced }
    private var reduced = FocusState()
    /// Topologies their owners marked changed, built when next needed (`setNeedsTopology`).
    private var pendingTopologies: [(owner: ObjectIdentifier, build: @MainActor () -> FocusTopology?)] = []
    /// The state and rules (`cmux-focus-core`); the view above mirrors it.
    private let machine = FocusMachine()
    private var appliedCloseFocus: CloseFocusPolicy?
    /// The close-focus setting (tests inject one).
    var closeFocus: () -> CloseFocusPolicy = { DesignSettings.shared.closeFocus }
    weak var applier: (any FocusEffectApplying)?
    /// The window this coordinator focuses in (`debug.pane_focus` times its commit).
    weak var window: NSWindow?
    private var queue: [FocusEvent] = []
    private var isRunning = false
    /// Tabs left while their address bar had the keyboard (Chrome restores it on return).
    private var omnibarMemory = OmnibarFocusMemory()
    /// The applier runs the address-bar focus of a return to the tab (``OmnibarFocusMemory/takeReturn(_:)``).
    private(set) var isReturningToOmnibar = false
    private(set) var isApplying = false
    /// The last events, newest last (for `debug.focus`).
    private(set) var recent: [String] = []
    /// The pane a Close Tab press is aimed at after a close emptied a pane (``PaneCloseAim``).
    private(set) var closeAim = PaneCloseAim()
    /// Calls its body with the time (system uptime) the frame carrying this turn's changes is
    /// presented: the next Core Animation commit plus one refresh of `window`'s screen. Tests pass their own.
    var framePresented: @MainActor (NSWindow?, @escaping @MainActor (TimeInterval) -> Void) -> Void = FocusCoordinator.nextFramePresented
    private static let recentLimit = 32

    /// What the coordinator did, for the input journal and the invariant
    /// monitor (plans/cmux-next/input-spec.md).
    enum Observation {
        /// `event` took `before` to `after`; its effects run next. `changed`:
        /// the focus changed or the event had effects (else it was a no-op).
        case reduced(FocusEvent, before: FocusState, after: FocusState, changed: Bool)
        /// A responder report dropped as the echo of the applier's own change.
        case suppressedResponder(FocusEvent.Responder)
        /// A focus or selection change dropped: the action run sending it
        /// may not change this client's view (`ActionRunScope.viewChangeAllowed()`).
        case refusedByRun(FocusEvent)
    }

    /// Called after every reduction, before its effects run.
    var observer: ((Observation) -> Void)?
    /// Called once the queue drained and every effect ran (notifications).
    var settledObserver: ((FocusState) -> Void)?

    func send(_ event: FocusEvent) {
        // An action run that may not change this client's view (a CLI,
        // script, agent or remote run without `focus: true`) never moves
        // focus or selection, nor bumps the intent generation, which would
        // void the user's own pending expectation (OWNERSHIP-PRINCIPLES.md).
        // The permission is read first: only a refusing run asks the rule.
        if !ActionRunScope.viewChangeAllowed(), event.changesView {
            observer?(.refusedByRun(event))
            return
        }
        // A changed topology goes first: the event (and its effects) see the current panes and tabs.
        if case .topology = event {} else { reducePendingTopologies() }
        queue.append(event)
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        // debug.pane_focus: a drain that lands on another pane is one timed move (a key, a click, pane.focus).
        let paneBefore = reduced.pane
        DebugPaneFocus.began(self)
        defer {
            if reduced.pane != paneBefore, reduced.pane != nil { DebugPaneFocus.shown(self, in: window) } else { DebugPaneFocus.dropped(self) }
            if reduced.pane != paneBefore { paneMoved(from: paneBefore) }
        }
        // The settled observer can send or reduce a pending topology: what it queued runs too. The
        // queue holds this event, so the drain runs at least once, and it ends when the queue is empty.
        while !queue.isEmpty {
            while !queue.isEmpty {
                let event = queue.removeFirst()
                let returnsToOmnibar = omnibarMemory.takeReturn(event)
                // A topology equal to the one the machine holds is not an event:
                // nothing is sent, recorded or applied (the window re-reports
                // its panes after every daemon delta and selection echo).
                if case .topology(let topology) = event, topology == reduced.topology { continue }
                // `layout.closeFocus` is read per event: a settings change
                // applies to the next close.
                let policy = closeFocus()
                if appliedCloseFocus != policy {
                    appliedCloseFocus = policy
                    machine.setCloseFocus(mostRecent: policy == .mostRecent)
                }
                let previous = reduced
                guard let result = machine.send(event, into: &reduced) else {
                    // The ABI refused the event: a wire mismatch between the app
                    // and the linked FFI. Keep the state rather than lose focus.
                    assertionFailure("focus machine refused \(event)")
                    continue
                }
                let effects = result.effects
                DebugPaneFocus.mark(self, "reduced")
                record(event)
                if omnibarMemory.note(event, before: previous.resolved, after: reduced.resolved) {
                    // Runs after this event's effects moved the responder to the page.
                    queue.append(OmnibarFocusMemory.returnEvent)
                }
                observer?(.reduced(event, before: previous, after: reduced, changed: result.changed || !effects.isEmpty))
                guard !effects.isEmpty, let applier else { continue }
                isApplying = true
                isReturningToOmnibar = returnsToOmnibar
                applier.apply(effects, state: reduced)
                isReturningToOmnibar = false
                isApplying = false
                DebugPaneFocus.mark(self, "applied")
            }
            settledObserver?(reduced)
            DebugPaneFocus.mark(self, "settled")
        }
    }

    /// The state after every pending topology: for a reader that decides on it now, outside
    /// AppKit's own responder change (a key-down's routing; the window judging a page's own focus
    /// ask before that change begins, `AgentPaneView.refusesSelfFocus`).
    func currentState() -> FocusState {
        reducePendingTopologies()
        return reduced
    }

    /// The focus history of `workspace` (nil: the shown one), newest first:
    /// the successor of a closed pane and the tie-breaker of directional
    /// focus (focus.md section 4a). Read from the machine on request.
    func recentPanes(in workspace: String? = nil) -> [String] {
        reducePendingTopologies()
        return machine.recentPanes(in: workspace)
    }

    /// The last focused pane of each workspace (restored on switching back).
    func rememberedPanes() -> [String: String] {
        reducePendingTopologies()
        return machine.remembered()
    }

    /// The machine's whole state, for the input journal's checkpoints.
    func checkpoint() -> FocusCheckpoint {
        reducePendingTopologies()
        return machine.checkpoint()
    }

    /// `owner`'s topology changed (a pane's tabs or selection). All changes of one main-actor turn
    /// (every pane of a restore, of one daemon batch) build and send ONE topology per owner: at the
    /// end of the turn, or at once before anything reads this coordinator's state or sends it an
    /// event, so no reader and no event sees the older one (I4). `build` returns nil when the owner
    /// sends none now (parked, or inside an apply that sends its own at its end).
    func setNeedsTopology(owner: AnyObject, _ build: @escaping @MainActor () -> FocusTopology?) {
        let id = ObjectIdentifier(owner)
        guard !pendingTopologies.contains(where: { $0.owner == id }) else { return }
        pendingTopologies.append((id, build))
        guard pendingTopologies.count == 1 else { return }
        // task-owner: the coordinator (weak); one per burst, ends after one reduction. Detached: not
        // under the task-locals (ActionRunScope) of the action run whose change came first.
        Task.detached { @MainActor [weak self] in self?.reducePendingTopologies() }
    }

    /// `owner` sends its current topology itself: its pending one is that one.
    func topologySent(by owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        pendingTopologies.removeAll { $0.owner == id }
    }

    private func reducePendingTopologies() {
        guard !pendingTopologies.isEmpty else { return }
        let pending = pendingTopologies
        pendingTopologies.removeAll()
        for entry in pending {
            if let topology = entry.build() { send(.topology(topology)) }
        }
    }

    /// Stamps the focused pane's move with the presentation of the frame that shows it (``closeAim``).
    private func paneMoved(from before: String?) {
        let serial = closeAim.paneMoved(from: before, to: reduced.pane)
        framePresented(window) { [weak self] time in self?.closeAim.presented(serial, at: time) }
    }

    /// `press` closed the last tab of `pane` (``PaneCloseAim/paneEmptied(_:by:)``).
    func noteEmptied(_ pane: String, by press: PaneCloseAim.Press) {
        closeAim.paneEmptied(pane, by: press)
    }

    /// Whether `press` is aimed at a pane a close emptied, not at the focused pane (``PaneCloseAim``).
    func aimsAtEmptiedPane(_ press: PaneCloseAim.Press) -> Bool {
        let focused = currentState().pane
        return closeAim.aimsAtEmptiedPane(press, focused: focused)
    }

    /// ``framePresented`` in the app. A commit reaches the screen at the display's next refresh, so
    /// the frame is presented one refresh interval after it (the interval of `window`'s screen, at
    /// its highest rate; 60 Hz without a screen). A boundary that missed the turn's commit fires
    /// after the next wake, later than the real commit: presses before it count as unseen.
    static func nextFramePresented(_ window: NSWindow?, _ body: @escaping @MainActor (TimeInterval) -> Void) {
        let rate = window?.screen?.maximumFramesPerSecond ?? 60
        let refresh = 1 / Double(max(rate, 1))
        CommitBoundary().after { _ in body(ProcessInfo.processInfo.systemUptime + refresh) }
    }

    /// Starts a user intent that lands later (split, new tab). Pass the
    /// returned generation to `expect`.
    func beginIntent() -> UInt64 {
        send(.beginIntent)
        return reduced.generation
    }

    /// Focuses `key` when it exists unless a newer intent happened since
    /// `generation` (nil: now, for app-driven creations). With `awayFrom`
    /// it lands only once the tab is in a pane other than that one. `.surface`: `rekeySurfaceWait`.
    func expect(_ key: FocusState.Expectation.Key, target: FocusState.Target = .content, awayFrom: String? = nil,
                generation: UInt64? = nil) {
        send(.expect(key, target: target, awayFrom: awayFrom, generation: generation ?? reduced.generation))
    }

    /// A user moved `tab` out of `pane` (shortcut, menu, CLI): focus
    /// follows it into its new pane once the daemon reports the move.
    func followMovedTab(_ tab: String, from pane: String) {
        send(.dragEnded(.dropped(tabs: [tab], awayFrom: pane)))
    }

    /// An AppKit responder change. Ignored while this coordinator applies
    /// its own effects (echo suppression).
    func responderDidChange(_ responder: FocusEvent.Responder, source: FocusEvent.Source) {
        guard !isApplying else {
            observer?(.suppressedResponder(responder))
            return
        }
        send(.responder(responder, source: source))
    }

    private func record(_ event: FocusEvent) {
        recent.append(Self.describe(event))
        if recent.count > Self.recentLimit { recent.removeFirst(recent.count - Self.recentLimit) }
    }

    private static func describe(_ event: FocusEvent) -> String {
        switch event {
        case .topology(let topology): "topology(\(topology.workspace ?? "-"), \(topology.panes.count) panes)"
        default: String(describing: event)
        }
    }
}

extension FocusEvent.Source {
    /// Mouse or keyboard from the event AppKit is dispatching, else programmatic (`NSApp.currentEvent`
    /// stays the last event after its dispatch, so it counts only inside `sendEvent`; cx-3hw0i.2).
    static var current: FocusEvent.Source {
        switch (NSApp as? CmuxApplication)?.isHandlingSendEvent() == true ? NSApp.currentEvent?.type : nil {
        case .keyDown, .keyUp, .flagsChanged: .keyboard
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged: .mouse
        default: .programmatic
        }
    }

    /// For user-invoked actions (registry handlers): the current input
    /// device, else the CLI or a scripted run (still a user intent).
    static var intent: FocusEvent.Source {
        let source = current
        return source == .programmatic ? .cli : source
    }
}
