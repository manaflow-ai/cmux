import AppKit

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
    private(set) var state = FocusState()
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
        /// `event` took `before` to `after`; its effects run next.
        case reduced(FocusEvent, before: FocusState, after: FocusState)
        /// A responder report dropped as the echo of the applier's own change.
        case suppressedResponder(FocusEvent.Responder)
    }

    /// Called after every reduction, before its effects run.
    var observer: ((Observation) -> Void)?
    /// Called once the queue drained and every effect ran (notifications).
    var settledObserver: ((FocusState) -> Void)?

    func send(_ event: FocusEvent) {
        queue.append(event)
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while !queue.isEmpty {
            let event = queue.removeFirst()
            let previous = state
            let (next, effects) = FocusReducer.reduce(previous, event)
            state = next
            record(event)
            observer?(.reduced(event, before: previous, after: next))
            guard !effects.isEmpty, let applier else { continue }
            isApplying = true
            applier.apply(effects, state: next)
            isApplying = false
        }
        settledObserver?(state)
    }

    /// Starts a user intent that lands later (split, new tab). Pass the
    /// returned generation to `expect`.
    func beginIntent() -> UInt64 {
        send(.beginIntent)
        return state.generation
    }

    /// Focuses `key` when it exists unless a newer intent happened since
    /// `generation` (nil: now, for app-driven creations). With `awayFrom`
    /// it lands only once the tab is in a pane other than that one.
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
    /// Mouse or keyboard from the event AppKit is dispatching, else
    /// programmatic.
    static var current: FocusEvent.Source {
        switch NSApp.currentEvent?.type {
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
