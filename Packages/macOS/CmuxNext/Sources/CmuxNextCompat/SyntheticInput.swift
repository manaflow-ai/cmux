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
/// posted event has its own `systemUptime`); bounded, so an event that
/// never arrives is forgotten.
///
/// A synthetic press also holds its button, as the hardware does, from the
/// dispatch of its mouse-down to that of its mouse-up: `NSEvent.pressedMouseButtons`
/// adds it to the hardware's buttons. WebKit and Chromium take a pointer
/// event's `buttons` from there, not from the event, so without it a page's
/// pointer drag (the sidebar's Updated card) saw a move with no button and
/// ended at the first synthesized move.
@MainActor
public enum SyntheticInput {
    private struct Key: Hashable {
        var type: UInt
        var timestamp: TimeInterval
    }

    /// The registered events not dispatched yet, and the buttons synthetic presses hold
    /// (`NSEvent.pressedMouseButtons` bits: 1 left, 2 right, 4 middle). Changed on the main
    /// actor as events are posted and dispatched; the swapped getter reads `held` on any thread.
    private struct State {
        var pending: [Key] = []
        var held = 0
        var log: [String] = []
    }

    /// SCRATCH readback probe (never landed).
    public nonisolated static func debugLog() -> String {
        state.withLock { "held=\($0.held) pending=\($0.pending.map { "\($0.type)@\($0.timestamp)" }.suffix(6)) log=\($0.log.suffix(16))" }
    }

    private nonisolated static let state = Mutex(State())
    private static let limit = 256

    public static func register(_ events: [NSEvent]) {
        state.withLock { state in
            state.pending.append(contentsOf: events.map { Key(type: $0.type.rawValue, timestamp: $0.timestamp) })
            if state.pending.count > limit { state.pending.removeFirst(state.pending.count - limit) }
        }
    }

    /// Whether `event` is the user's own input (not one `register`ed). Called
    /// once per event as it is dispatched; a synthetic press or release
    /// changes the buttons its later events see held.
    public static func isUserInput(_ event: NSEvent) -> Bool {
        let key = Key(type: event.type.rawValue, timestamp: event.timestamp)
        let bit = buttonBit(event)
        let user = state.withLock { state in
            if bit != 0 || event.type == .leftMouseDragged {
                state.log.append("\(event.type.rawValue)@\(event.timestamp) m=\(state.pending.contains(key))")
            }
            guard let index = state.pending.firstIndex(of: key) else { return true }
            // Events dispatch in the order they were posted: one registered before this one that never came
            // was taken by a tracking loop (`nextEvent(matching:)`: a native button's or a text selection's),
            // so its release lets go of its button here.
            for skipped in state.pending[..<index] {
                state.held &= ~releasedBit(skipped.type)
            }
            state.pending.removeSubrange(...index)
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown: state.held |= bit
            default: state.held &= ~bit
            }
            return false
        }
        if !user, bit != 0 { _ = installed }
        return user
    }

    /// The `pressedMouseButtons` bit a press or release of `event` changes, or 0 (not a press or release).
    private static func buttonBit(_ event: NSEvent) -> Int {
        switch event.type {
        case .leftMouseDown, .leftMouseUp: 1
        case .rightMouseDown, .rightMouseUp: 2
        case .otherMouseDown, .otherMouseUp: 1 << min(max(event.buttonNumber, 2), 31)
        default: 0
        }
    }

    /// The button a release of raw event type `type` lets go of, or 0.
    private nonisolated static func releasedBit(_ type: UInt) -> Int {
        switch NSEvent.EventType(rawValue: type) {
        case .leftMouseUp: 1
        case .rightMouseUp: 2
        case .otherMouseUp: 4
        default: 0
        }
    }

    /// The buttons synthetic presses hold now.
    nonisolated static var held: Int { state.withLock { $0.held } }

    /// AppKit's `pressedMouseButtons` getter swapped, once, for one that adds `held`.
    private static let installed: Bool = {
        guard let system = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)),
              let held = class_getClassMethod(NSEvent.self, #selector(getter: NSEvent.cmuxPressedMouseButtonsWithSynthetic))
        else { return false }
        method_exchangeImplementations(system, held)
        return true
    }()
}

extension NSEvent {
    /// After `SyntheticInput` swaps the two getters this name runs AppKit's
    /// own `pressedMouseButtons`, and `pressedMouseButtons` runs this body.
    @objc fileprivate dynamic class var cmuxPressedMouseButtonsWithSynthetic: Int {
        cmuxPressedMouseButtonsWithSynthetic | SyntheticInput.held
    }
}
