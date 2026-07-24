/// The ordered terminal operations and physical-key ownership for one native key.
public struct TerminalKeyInputPlan: Sendable, Equatable {
    /// Ordered libghostty operations.
    public let actions: [TerminalKeyInputAction]

    /// Whether libghostty receives an encodable physical press that owns key-up.
    ///
    /// A composing key operation is intentionally excluded because libghostty
    /// suppresses non-modifier presses while composition is active.
    public var forwardsPhysicalKey: Bool {
        actions.contains { action in
            guard case .sendKey(_, composing: false) = action else { return false }
            return true
        }
    }

    init(actions: [TerminalKeyInputAction]) {
        self.actions = actions
    }
}
