public import Foundation

/// One window of a classic cmux session: its workspaces in sidebar order and its groups.
public nonisolated struct ClassicSessionWindow: Codable, Equatable, Sendable {
    /// Classic's window id (`windowId`); nil in older snapshots.
    public let id: String?
    /// The window's frame in screen coordinates (`frame`); nil when classic saved none.
    public let frame: CGRect?
    /// The index into ``workspaces`` that was selected (`selectedWorkspaceIndex`).
    public let selectedWorkspace: Int?
    public let workspaces: [ClassicSessionWorkspace]
    /// Groups in sidebar order.
    public let groups: [ClassicSessionGroup]

    public init(id: String? = nil, frame: CGRect? = nil, selectedWorkspace: Int? = nil,
                workspaces: [ClassicSessionWorkspace], groups: [ClassicSessionGroup] = []) {
        self.id = id
        self.frame = frame
        self.selectedWorkspace = selectedWorkspace
        self.workspaces = workspaces
        self.groups = groups
    }
}
