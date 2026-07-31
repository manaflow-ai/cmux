/// The ordered terminal operations and physical-key ownership for one native key.
public struct TerminalKeyInputPlan: Sendable, Equatable {
    /// Ordered libghostty operations.
    public let actions: [TerminalKeyInputAction]

    /// Whether libghostty receives an encodable physical press that owns key-up.
    ///
    /// Composing presses still reach libghostty even when its encoder emits no
    /// terminal bytes, so they retain their native repeat and release lifecycle.
    public var forwardsPhysicalKey: Bool {
        actions.contains(where: \.forwardsPhysicalKey)
    }

    init(actions: [TerminalKeyInputAction]) {
        self.actions = actions
    }
}
