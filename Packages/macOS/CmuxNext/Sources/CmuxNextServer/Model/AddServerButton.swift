import Foundation

/// One button of the sheet's footer: its action, the key that presses it, and whether it is on.
public nonisolated struct AddServerButton: Equatable, Sendable {
    /// What the button does.
    public var action: AddServerAction
    /// Whether the button is the Return button (`true`) or the Escape button (`false`).
    public var isDefault: Bool
    /// Whether a click or the key runs it.
    public var enabled: Bool

    public init(action: AddServerAction, isDefault: Bool, enabled: Bool) {
        self.action = action
        self.isDefault = isDefault
        self.enabled = enabled
    }
}
