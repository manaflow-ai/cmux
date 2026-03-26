import Foundation
import Combine

/// A named, collapsible group of workspace tabs in the sidebar.
@MainActor
final class ProjectGroup: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var color: String?
    @Published var isCollapsed: Bool
    @Published var workspaceIds: [UUID]

    init(id: UUID = UUID(), name: String, color: String? = nil, isCollapsed: Bool = false, workspaceIds: [UUID] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.workspaceIds = workspaceIds
    }
}

/// Represents a top-level item in the sidebar ordering.
enum SidebarOrderItem: Equatable {
    case group(UUID)
    case workspace(UUID)
}

// Grouped workspaces do NOT appear here — their order is in ProjectGroup.workspaceIds.
extension SidebarOrderItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        let id = try container.decode(UUID.self, forKey: .id)
        switch type {
        case "group": self = .group(id)
        case "workspace": self = .workspace(id)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported sidebar order item type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .group(let id):
            try container.encode("group", forKey: .type)
            try container.encode(id, forKey: .id)
        case .workspace(let id):
            try container.encode("workspace", forKey: .type)
            try container.encode(id, forKey: .id)
        }
    }
}

/// Value-typed row model for group headers in the sidebar.
struct GroupRowModel: Identifiable, Equatable {
    let id: UUID
    let name: String
    let color: String?
    let isCollapsed: Bool
    let workspaceCount: Int
}

/// Value-typed row model for workspace rows in the sidebar.
/// Does NOT hold a Workspace reference — resolve by ID for actions.
struct WorkspaceRowModel: Identifiable, Equatable {
    let id: UUID
    let parentGroupId: UUID?
    let title: String
    let customColor: String?
    let isPinned: Bool

    var isIndented: Bool { parentGroupId != nil }
}

/// A single row in the sidebar display list.
enum SidebarDisplayItem: Identifiable, Equatable {
    case groupHeader(GroupRowModel)
    case workspace(WorkspaceRowModel)

    var id: UUID {
        switch self {
        case .groupHeader(let model): return model.id
        case .workspace(let model): return model.id
        }
    }
}

/// Resolved drop target action from the sidebar drop planner.
enum SidebarDropResolution {
    case reorderTopLevel(item: SidebarOrderItem, toIndex: Int)
    case moveWorkspaceToGroup(workspaceId: UUID, groupId: UUID, groupIndex: Int?)
    case moveWorkspaceOutOfGroup(workspaceId: UUID, sidebarIndex: Int)
    case reorderWithinGroup(workspaceId: UUID, groupId: UUID, toIndex: Int)
}
