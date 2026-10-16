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

public nonisolated struct SidebarPriorityItem: Identifiable, Hashable, Sendable {
    public let workspace: SidebarWorkspace
    public let bucket: SidebarPriorityBucket

    public var id: WorkspaceID { workspace.id }

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
        sections.map { section in
            guard section.id != .pinned else { return section }
            var result = section
            result.nodes = section.nodes
                .map { node -> SidebarNode in
                    guard case let .group(existingGroup) = node else { return node }
                    var group = existingGroup
                    group.workspaces = ordered(group.workspaces)
                    return .group(group)
                }
                .sorted { lhs, rhs in
                    nodeRank(lhs) < nodeRank(rhs)
                }
            return result
        }
    }

    private func nodeRank(_ node: SidebarNode) -> Int {
        node.workspaces.map { workspace in
            workspace.rowState == .placeholder ? SidebarPriorityBucket.idle.rawValue : SidebarPriorityItem(workspace: workspace).bucket.rawValue
        }.min() ?? SidebarPriorityBucket.idle.rawValue
    }

    private func ordered(_ workspaces: [SidebarWorkspace]) -> [SidebarWorkspace] {
        workspaces
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.rowState == .placeholder ? SidebarPriorityBucket.idle.rawValue : SidebarPriorityItem(workspace: lhs.element).bucket.rawValue
                let right = rhs.element.rowState == .placeholder ? SidebarPriorityBucket.idle.rawValue : SidebarPriorityItem(workspace: rhs.element).bucket.rawValue
                if left != right { return left < right }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
