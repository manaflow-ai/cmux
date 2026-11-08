import Foundation

/// `selection-changed` (`tree-selection-deltas-v1`, #32408): the whole selection of one workspace, as the
/// daemon has it when it writes the event. It replaces the coarse `tree-changed` the daemon sent for a
/// selection change that rides with a tree delta (a create's focus, a new tab that becomes its pane's
/// active tab), which made the store read the whole tree again.
///
/// A screen or pane the store does not hold yet is skipped: its own add delta, still on its way, carries
/// its selection.
/// `workspace-presentation-changed` (`tree-selection-deltas-v1`, #32408): one workspace's entity after a
/// `workspace.update` of its title, color or icon, which has no workspace revision. It replaces the
/// `tree-changed` that made the store read the whole tree for one workspace's color.
public struct WorkspacePresentationDelta: Sendable, Hashable, Decodable {
    public var workspace: WorkspaceHandle
    public var entity: WorkspaceSnapshot
}

public struct SelectionDelta: Sendable, Hashable, Decodable {
    public struct Pane: Sendable, Hashable, Decodable {
        public var id: PaneID
        public var activeTab: Int
        public var focusedAt: UInt64

        enum CodingKeys: String, CodingKey {
            case id
            case activeTab = "active_tab"
            case focusedAt = "focused_at"
        }
    }

    public struct Screen: Sendable, Hashable, Decodable {
        public var id: ScreenID
        public var active: Bool
        public var activePane: PaneID?
        public var panes: [Pane]

        enum CodingKeys: String, CodingKey {
            case id, active, panes
            case activePane = "active_pane"
        }
    }

    public var workspace: WorkspaceHandle
    public var screens: [Screen]
}
