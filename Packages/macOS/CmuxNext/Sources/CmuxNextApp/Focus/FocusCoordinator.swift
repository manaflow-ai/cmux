import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextFocus

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
    /// The read view of the machine's state (refreshed from each reply).
    private(set) var state = FocusState()
    /// The state and rules (`cmux-focus-core`); the view above mirrors it.
    private let machine = FocusMachine()
    private var appliedCloseFocus: CloseFocusPolicy?
    /// The close-focus setting (tests inject one).
    var closeFocus: () -> CloseFocusPolicy = { DesignSettings.shared.closeFocus }
    weak var applier: (any FocusEffectApplying)?
    private var queue: [FocusEvent] = []
    private var isRunning = false
    private(set) var isApplying = false
    /// The last events, newest last (for `debug.focus`).
    private(set) var recent: [String] = []
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
        queue.append(event)
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while !queue.isEmpty {
            let event = queue.removeFirst()
            // A topology equal to the one the machine holds is not an event:
            // nothing is sent, recorded or applied (the window re-reports
            // its panes after every daemon delta and selection echo).
            if case .topology(let topology) = event, topology == state.topology { continue }
            // `layout.closeFocus` is read per event: a settings change
            // applies to the next close.
            let policy = closeFocus()
            if appliedCloseFocus != policy {
                appliedCloseFocus = policy
                machine.setCloseFocus(mostRecent: policy == .mostRecent)
            }
            let previous = state
            guard let result = machine.send(event, into: &state) else {
                // The ABI refused the event: a wire mismatch between the app
                // and the linked FFI. Keep the state rather than lose focus.
                assertionFailure("focus machine refused \(event)")
                continue
            }
            let effects = result.effects
            record(event)
            observer?(.reduced(event, before: previous, after: state, changed: result.changed || !effects.isEmpty))
            guard !effects.isEmpty, let applier else { continue }
            isApplying = true
            applier.apply(effects, state: state)
            isApplying = false
        }
        settledObserver?(state)
    }

    /// The focus history of `workspace` (nil: the shown one), newest first:
    /// the successor of a closed pane and the tie-breaker of directional
    /// focus (focus.md section 4a). Read from the machine on request.
    func recentPanes(in workspace: String? = nil) -> [String] {
        machine.recentPanes(in: workspace)
    }

    /// The last focused pane of each workspace (restored on switching back).
    func rememberedPanes() -> [String: String] { machine.remembered() }

    /// The machine's whole state, for the input journal's checkpoints.
    func checkpoint() -> FocusCheckpoint { machine.checkpoint() }

    /// Starts a user intent that lands later (split, new tab). Pass the
    /// returned generation to `expect`.
    func beginIntent() -> UInt64 {
        send(.beginIntent)
        return state.generation
    }

    /// Focuses `key` when it exists unless a newer intent happened since
    /// `generation` (nil: now, for app-driven creations). With `awayFrom`
    /// it lands only once the tab is in a pane other than that one. `.surface` finds no tab this
    /// window minted (``TabModel/isClientMinted``): those take `.tab`.
    func expect(_ key: FocusState.Expectation.Key, target: FocusState.Target = .content, awayFrom: String? = nil,
                generation: UInt64? = nil) {
        send(.expect(key, target: target, awayFrom: awayFrom, generation: generation ?? state.generation))
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
