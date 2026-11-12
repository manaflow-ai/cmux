public import AppKit
internal import ObjectiveC

/// Input an agent posted into this app (`debug.mouse`), told apart from the
/// user's own input. Posted events take the path real ones take
/// (`CmuxApplication.sendEvent`), so without this the no-activate keyboard
/// guard would count an agent's press as the user choosing the app and
/// keep an activation that came right after it.
///
/// `DebugMouse` registers each press before posting it; the guard asks
/// `isUserInput` as the press arrives. Matched by type and timestamp (each
/// posted event has its own `systemUptime`, kept to the nanosecond in the
/// queue); bounded, so an event that never arrives is forgotten.
///
/// A synthetic press also holds its button, as the hardware does, from the
/// dispatch of its mouse-down to that of its mouse-up: `NSEvent.pressedMouseButtons`
/// adds it to the hardware's buttons. WebKit and Chromium take a pointer
/// event's `buttons` from there, not from the event, so without it a page's
/// pointer drag (the sidebar's Updated card) saw a move with no button and
/// ended at the first synthesized move.
@MainActor
public struct SyntheticInput {
    public init() {}
    /// A registered event not dispatched yet, with the button its press or release changes.
    private struct Pending {
        var type: UInt
        var timestamp: TimeInterval
        var bit: Int

        /// The posted event's own stamp: the queue keeps it to the nanosecond, so a dispatched
        /// event's timestamp can differ from the one it was made with in the last digits (a
        /// capture's press read as the person's, its button never held). Within a microsecond is
        /// the same event; the oldest pending one of that type is taken first.
        func matches(_ event: NSEvent) -> Bool {
            type == event.type.rawValue && abs(timestamp - event.timestamp) < 0.000_001
        }
    }

    /// The registered events not dispatched yet, the buttons synthetic presses hold
    /// (`NSEvent.pressedMouseButtons` bits: 1 left, 2 right, 1 << n other button n), and whether
    /// the getter is swapped. Changed on the main actor as events are posted and dispatched; the
    /// swapped getter reads `held` on any thread.
    private struct State {
        var pending: [Pending] = []
        var held = 0
        /// The buttons a click handed straight to a view holds (``click(_:down:up:)``), apart from `held`.
        var direct = 0
        var swapped = false
    }

    private nonisolated static let state = Mutex(State())
    private static let limit = 256

    public static func register(_ events: [NSEvent]) {
        state.withLock { state in
            state.pending.append(contentsOf: events.map {
                Pending(type: $0.type.rawValue, timestamp: $0.timestamp, bit: buttonBit($0))
            })
            if state.pending.count > limit { state.pending.removeFirst(state.pending.count - limit) }
        }
    }

    /// Whether `event` is the user's own input (not one `register`ed). Called
    /// once per event as it is dispatched; a synthetic press or release
    /// changes the buttons its later events see held.
    public static func isUserInput(_ event: NSEvent) -> Bool {
        let bit = buttonBit(event)
        let (user, held) = state.withLock { state -> (Bool, Int) in
            guard let index = state.pending.firstIndex(where: { $0.matches(event) }) else { return (true, state.held) }
            // Events dispatch in the order they were posted: one registered before this one that never came
            // was taken by a tracking loop (`nextEvent(matching:)`: a native button's or a text selection's),
            // so its release lets go of its button here.
            for skipped in state.pending[..<index] where isRelease(skipped.type) {
                state.held &= ~skipped.bit
            }
            state.pending.removeSubrange(...index)
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: state.held |= bit
            default: state.held &= ~bit
            }
            return (false, state.held)
        }
        if !user, bit != 0 { _ = installed }
        // A release a tracking loop took with no synthetic event after it: the person's own mouse
        // event, with no hardware button down, ends the synthetic press (hover and focus-follows-mouse
        // skip while a button is held).
        if user, held != 0, isMouse(event.type), hardwareButtons == 0 {
            state.withLock { $0.held = 0 }
        }
        return user
    }

    /// A synthetic click handed straight to `view` (`mouseDown(with:)`, `mouseUp(with:)`), not through `sendEvent`
    /// (a page window that is not key drops a posted click). As through `sendEvent`, the press holds its button while
    /// the view takes it, and the release lets go before the view takes it.
    /// Its hold is its own (`direct`), outside the queue's bookkeeping: it never consumes or prunes another caller's
    /// posted events still queued (they stay synthetic and hold their button), and its release never lets go of a
    /// posted press still held (a capture's open drag).
    public static func click(_ view: NSView, down: NSEvent, up: NSEvent) {
        let bit = buttonBit(down)
        if bit != 0 { _ = installed }
        state.withLock { $0.direct |= bit }
        view.mouseDown(with: down)
        state.withLock { $0.direct &= ~bit }
        view.mouseUp(with: up)
    }

    /// The `pressedMouseButtons` bit a press or release of `event` changes, or 0 (not a press or release).
    private nonisolated static func buttonBit(_ event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: 1
        case .rightMouseDown, .rightMouseUp: 2
        case .otherMouseDown, .otherMouseUp: 1 << min(max(event.buttonNumber, 2), 31)
        default: 0
        }
    }

    private nonisolated static func isRelease(_ type: UInt) -> Bool {
        [.leftMouseUp, .rightMouseUp, .otherMouseUp].contains(NSEvent.EventType(rawValue: type))
    }

    private static func isMouse(_ type: NSEvent.EventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .rightMouseUp,
             .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged, .scrollWheel: true
        default: false
        }
    }

    /// The buttons the hardware holds, without synthetic presses: what the no-activate guard reads, since
    /// an agent's press is not the person choosing the app.
    public nonisolated static var hardwareButtons: Int {
        state.withLock { $0.swapped } ? NSEvent.cmuxPressedMouseButtonsWithSynthetic : NSEvent.pressedMouseButtons
    }

    /// The buttons synthetic presses hold now.
    nonisolated static var held: Int { state.withLock { $0.held | $0.direct } }

    /// AppKit's `pressedMouseButtons` getter swapped, once, for one that adds `held`.
    private static let installed: Bool = {
        guard let system = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)),
              let held = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.cmuxPressedMouseButtonsWithSynthetic))
        else { return false }
        method_exchangeImplementations(system, held)
        state.withLock { $0.swapped = true }
        return true
    }()
}

extension NSEvent {
    /// After `SyntheticInput` swaps the two getters this name runs AppKit's
    /// own `pressedMouseButtons` (``SyntheticInput/hardwareButtons``), and
    /// `pressedMouseButtons` runs this body.
    @objc fileprivate dynamic class var cmuxPressedMouseButtonsWithSynthetic: Int {
        cmuxPressedMouseButtonsWithSynthetic | SyntheticInput.held
    }
}
