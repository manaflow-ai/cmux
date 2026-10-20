import Foundation
import CmuxNextDesign

/// The compact, high-signal ordering used by a Priority/Agent view.
///
/// Identity stays at the workspace layer: an agent session is represented by
/// the workspace containing its agent tab. Callers must resolve the
/// `sessionId -> agent tab -> WorkspaceID` relationship before constructing
/// these items; this type deliberately does not invent a second identity.
public nonisolated enum SidebarPriorityBucket: Int, Hashable, Sendable {
    /// An agent is waiting for a person to answer or approve something.
    case needsInput
    /// The latest agent run or task failed.
    case failed
    /// Work is currently running.
    case working
    /// Work completed recently and remains useful context.
    case finished
    /// No active or actionable state is reported.
    case idle
}

/// A workspace paired with the attention bucket used for ordering.
public nonisolated struct SidebarPriorityItem: Identifiable, Hashable, Sendable {
    /// The workspace represented by this item.
    public let workspace: SidebarWorkspace
    /// The workspace's current attention bucket.
    public let bucket: SidebarPriorityBucket

    /// The stable workspace identity.
    public var id: WorkspaceID { workspace.id }

    /// Creates a priority item from a workspace snapshot.
    public init(workspace: SidebarWorkspace) {
        self.workspace = workspace
        self.bucket = Self.bucket(for: workspace)
    }

    static func bucket(for workspace: SidebarWorkspace) -> SidebarPriorityBucket {
        if workspace.unread.isUnread || workspace.notificationText != nil { return .needsInput }
        return switch workspace.activity {
        case .waiting: .needsInput
        case .error: .failed
        case .working, .busy, .paused: .working
        case .success: .finished
        case .idle: workspace.agentWorking ? .working : .idle
        }
    }
}

/// Computes the dynamic attention order used by the workspace sidebar.
public nonisolated struct SidebarPriority: Sendable {
    /// Creates a stateless priority calculator.
    public init() {}

    /// Sorts actionable rows before working, finished and idle rows.
    ///
    /// The incoming order is the user's manual order. It is retained for ties,
    /// so changing a row's state promotes it without making manual placement
    /// fight the priority projection.
    public func items(_ workspaces: [SidebarWorkspace], limit: Int? = nil) -> [SidebarPriorityItem] {
        let sorted = workspaces
            .filter { $0.rowState != .placeholder }
            .map(SidebarPriorityItem.init)
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.bucket != rhs.element.bucket { return lhs.element.bucket.rawValue < rhs.element.bucket.rawValue }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        guard let limit else { return sorted }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Reorders live sections while preserving pins, groups and manual ties.
    /// Group members are ranked inside their group and the group itself is
    /// ranked by its strongest member, so a waiting agent brings its project
    /// group forward without flattening the user's organization.
    public func reordered(_ sections: [SidebarSection]) -> [SidebarSection] {
        // Workspace creation and snapshot publication refresh the sidebar many
        // times while a new row is still idle. The common case is already in
        // priority order; avoid copying and sorting every section on each
        // refresh. This keeps the attention projection cheap during Cmd-N
        // bursts without changing the ordering when a row becomes actionable.
        guard needsReorder(sections) else { return sections }
        return sections.map { section in
            guard section.id != .pinned else { return section }
            var result = section
            result.nodes = section.nodes
                .map { node -> SidebarNode in
                    guard case let .group(existingGroup) = node else { return node }
                    var group = existingGroup
                    group.workspaces = ordered(group.workspaces)
                    return .group(group)
                }
                .enumerated()
                .sorted { lhs, rhs in
                    let leftRank = nodeRank(lhs.element)
                    let rightRank = nodeRank(rhs.element)
                    if leftRank != rightRank { return leftRank < rightRank }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
            return result
        }
    }

    private func needsReorder(_ sections: [SidebarSection]) -> Bool {
        for section in sections where section.id != .pinned {
            var previousNodeRank: Int?
            for node in section.nodes {
                if case let .group(group) = node {
                    var previousWorkspaceRank: Int?
                    for workspace in group.workspaces {
                        let rank = workspaceRank(workspace)
                        if let previousWorkspaceRank, rank < previousWorkspaceRank { return true }
                        previousWorkspaceRank = rank
                    }
                }
                let rank = nodeRank(node)
                if let previousNodeRank, rank < previousNodeRank { return true }
                previousNodeRank = rank
            }
        }
        return false
    }

    private func nodeRank(_ node: SidebarNode) -> Int {
        node.workspaces.map(workspaceRank).min() ?? SidebarPriorityBucket.idle.rawValue
    }

    private func workspaceRank(_ workspace: SidebarWorkspace) -> Int {
        workspace.rowState == .placeholder ? SidebarPriorityBucket.idle.rawValue : SidebarPriorityItem(workspace: workspace).bucket.rawValue
    }

    private func ordered(_ workspaces: [SidebarWorkspace]) -> [SidebarWorkspace] {
        workspaces
            .enumerated()
            .sorted { lhs, rhs in
                let left = workspaceRank(lhs.element)
                let right = workspaceRank(rhs.element)
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
