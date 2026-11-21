import CmuxNextDesign

/// The workspace a sidebar model selects after the shown one closed (plans/cmux-next/close-focus.md,
/// "One close-selection rule"): by position among the rows as drawn, with a state that holds no
/// relation. In the app a close goes through the window's selection repair
/// (`WindowRegistryStore.repairSelection`), which holds the opener relations; this serves a model
/// alone (the mock, a test), and `pick` lets one share a state with it.
public struct SidebarCloseSuccessor {
    /// The pick: the shown workspace, the rows before the close, the rows left, the row orders
    /// before the close (the rows as drawn).
    public var pick: (String?, [String], [String], [[String]]) -> String?

    public init() {
        let rule = CloseSelection<String>()
        pick = { rule.workspace(shown: $0, old: $1, surviving: $2, orders: $3) }
    }

    /// The row selected after `shown` closed: `old` the model's rows before, `surviving` its rows now, `drawn` the rows as the list drew them.
    public func callAsFunction(shown: WorkspaceID, old: [WorkspaceID], surviving: [WorkspaceID], drawn: [WorkspaceID]) -> WorkspaceID? {
        pick(shown.rawValue, old.map(\.rawValue), surviving.map(\.rawValue), [drawn.map(\.rawValue)]).map { WorkspaceID($0) }
    }
}
