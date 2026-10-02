/// What Cmd+digit selects: 1 is Home, 2…8 are the first seven workspaces
/// in sidebar order, and 9 is always the last workspace (a browser's
/// "last tab"). Digits past the end select the last workspace.
public nonisolated enum SidebarNumbering {
    public enum Target: Hashable, Sendable {
        case home
        case workspace(WorkspaceID)
    }

    public static func target(digit: Int, workspaces: [WorkspaceID]) -> Target? {
        guard (1...9).contains(digit) else { return nil }
        if digit == 1 { return .home }
        guard let last = workspaces.last else { return nil }
        if digit == 9 { return .workspace(last) }
        return .workspace(workspaces[min(digit - 2, workspaces.count - 1)])
    }
}
