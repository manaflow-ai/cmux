public import CmuxNextDaemon
public import Foundation

/// What a workspace did lately and what keeps it awake, read from the daemon store once per pass
/// (workspace hibernation, plans/cmux-next/workspace-hibernation-DESIGN.md; the same reads as
/// ``AutoArchiveCandidates``). Never read per frame or keystroke.
///
/// ```swift
/// let facts = WorkspaceActivityFacts.all(in: stores) { workspace, tabs in mounted.contains(workspace.id) }
/// ```
public nonisolated struct WorkspaceActivityFacts: Hashable, Sendable {
    /// The workspace's id.
    public var workspace: String
    /// The newest output, agent update or notification in its tabs; nil when none.
    public var lastActivity: Date?
    /// Pinned in the sidebar.
    public var pinned: Bool
    /// A command or an agent turn runs in one of its tabs.
    public var running: Bool
    /// An agent waits on the person, or it shows an error.
    public var needsAttention: Bool

    /// The facts of `workspace`, whose tabs are `tabs`.
    @MainActor
    public init(_ workspace: WorkspaceModel, tabs: [TabModel]) {
        let newest = tabs.map { max($0.lastOutputMs ?? 0, $0.agent?.updatedAtMs ?? 0, $0.notification?.createdAtMs ?? 0) }.max() ?? 0
        let asks: Bool = switch StatusMapping.shared.summary(tabs: tabs, status: workspace.status).state {
        case .waiting, .error: true
        default: false
        }
        self.workspace = workspace.id
        lastActivity = newest == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(newest) / 1000)
        pinned = workspace.pinned
        running = tabs.contains { $0.commandSinceMs != nil } || StatusMapping.shared.isWorking(tabs: tabs)
        needsAttention = asks
    }

    /// The facts of every workspace in `stores` that `included` takes (given the workspace and its tabs).
    @MainActor
    public static func all(in stores: [DaemonStore], where included: (WorkspaceModel, [TabModel]) -> Bool) -> [WorkspaceActivityFacts] {
        stores.flatMap(\.workspaces).compactMap { workspace in
            let tabs = workspace.screens.flatMap(\.panes).flatMap(\.tabs)
            return included(workspace, tabs) ? WorkspaceActivityFacts(workspace, tabs: tabs) : nil
        }
    }
}
