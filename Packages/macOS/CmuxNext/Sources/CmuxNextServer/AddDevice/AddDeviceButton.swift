/// One button of the Add Device card's footer: its action, the key that presses it, and its role.
public nonisolated struct AddDeviceButton: Equatable, Sendable {
    public nonisolated enum Key: Equatable, Sendable {
        case `return`
        case escape
    }

    public var action: AddDeviceAction
    /// Return, Escape, or none (a click only).
    public var key: Key?

    public init(action: AddDeviceAction, key: Key?) {
        self.action = action
        self.key = key
    }
}
