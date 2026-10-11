public import CmuxNextActions

/// A typed command on a palette row (plans/cmux-next/palette-scopes.md
/// 6.10): a catalog action with its target and arguments. `palette.run`
/// runs a row only through these refs, never through a row's closures, so
/// every headless run goes through the registry with the caller's origin.
/// The first ref of a row is its primary command.
public nonisolated struct PaletteActionRef: Sendable, Hashable {
    public var action: ActionID
    public var target: ActionTargetRef?
    public var arguments: [String: ActionValue]
    /// Nil uses the catalog title.
    public var title: String?
    public var isDestructive: Bool

    public init(_ action: ActionID, target: ActionTargetRef? = nil, arguments: [String: ActionValue] = [:],
                title: String? = nil, isDestructive: Bool = false) {
        self.action = action
        self.target = target
        self.arguments = arguments
        self.title = title
        self.isDestructive = isDestructive
    }
}
