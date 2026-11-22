import AppKit

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
@MainActor
enum SyntheticInput {
    private struct Key: Hashable {
        var type: UInt
        var timestamp: TimeInterval
    }

    private static var pending: [Key] = []
    private static let limit = 256

    static func register(_ events: [NSEvent]) {
        pending.append(contentsOf: events.map { Key(type: $0.type.rawValue, timestamp: $0.timestamp) })
        if pending.count > limit { pending.removeFirst(pending.count - limit) }
    }

    /// Whether `event` is the user's own input (not one `register`ed).
    static func isUserInput(_ event: NSEvent) -> Bool {
        let key = Key(type: event.type.rawValue, timestamp: event.timestamp)
        guard let index = pending.firstIndex(of: key) else { return true }
        pending.remove(at: index)
        return false
    }
}
