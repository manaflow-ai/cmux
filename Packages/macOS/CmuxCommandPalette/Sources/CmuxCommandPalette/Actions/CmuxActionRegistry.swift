import Foundation

/// Ordered registry of actions resolved for one live window context.
@MainActor
public struct CmuxActionRegistry {
    private var orderedActions: [CommandPaletteCommand] = []
    private var actionsByID: [String: CommandPaletteCommand] = [:]

    /// Creates an empty action registry.
    public init() {}

    /// All registered actions in their presentation order.
    public var actions: [CommandPaletteCommand] {
        orderedActions
    }

    /// Registers an action once. Duplicate IDs keep the first definition.
    @discardableResult
    public mutating func register(_ action: CommandPaletteCommand) -> Bool {
        guard actionsByID[action.id] == nil else { return false }
        actionsByID[action.id] = action
        orderedActions.append(action)
        return true
    }

    /// Resolves one action by stable identifier.
    public func action(id: String) -> CommandPaletteCommand? {
        actionsByID[id]
    }

    /// Validates and invokes one action.
    public func run(
        id: String,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult? {
        action(id: id)?.execute(invocation)
    }
}
