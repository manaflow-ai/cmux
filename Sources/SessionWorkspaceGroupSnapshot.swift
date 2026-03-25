import Foundation

/// Top-level sidebar layout snapshot for session persistence.
/// Stored as an optional field on `SessionTabManagerSnapshot` for backward compatibility.
struct SessionSidebarLayoutSnapshot: Codable, Sendable {
    var items: [SessionSidebarItemSnapshot]
}

/// A single entry in the top-level sidebar layout.
enum SessionSidebarItemSnapshot: Codable, Sendable {
    case standalone(workspaceIndex: Int)
    case group(SessionWorkspaceGroupSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case workspaceIndex
        case group
    }

    private enum ItemType: String, Codable {
        case standalone
        case group
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .standalone(let index):
            try container.encode(ItemType.standalone, forKey: .type)
            try container.encode(index, forKey: .workspaceIndex)
        case .group(let snapshot):
            try container.encode(ItemType.group, forKey: .type)
            try container.encode(snapshot, forKey: .group)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemType.self, forKey: .type)
        switch type {
        case .standalone:
            let index = try container.decode(Int.self, forKey: .workspaceIndex)
            self = .standalone(workspaceIndex: index)
        case .group:
            let snapshot = try container.decode(SessionWorkspaceGroupSnapshot.self, forKey: .group)
            self = .group(snapshot)
        }
    }
}

/// Snapshot of a workspace group for session persistence.
/// References workspaces by positional index into the workspaces array (not UUID).
struct SessionWorkspaceGroupSnapshot: Codable, Sendable {
    var title: String
    var color: String?
    var isCollapsed: Bool
    var isPinned: Bool
    var workingDirectory: String
    var items: [SessionGroupItemSnapshot]
}

/// A child item within a group snapshot.
enum SessionGroupItemSnapshot: Codable, Sendable {
    case workspace(workspaceIndex: Int)
    case group(SessionWorkspaceGroupSnapshot)

    private enum CodingKeys: String, CodingKey {
        case type
        case workspaceIndex
        case group
    }

    private enum ItemType: String, Codable {
        case workspace
        case group
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .workspace(let index):
            try container.encode(ItemType.workspace, forKey: .type)
            try container.encode(index, forKey: .workspaceIndex)
        case .group(let snapshot):
            try container.encode(ItemType.group, forKey: .type)
            try container.encode(snapshot, forKey: .group)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ItemType.self, forKey: .type)
        switch type {
        case .workspace:
            let index = try container.decode(Int.self, forKey: .workspaceIndex)
            self = .workspace(workspaceIndex: index)
        case .group:
            let snapshot = try container.decode(SessionWorkspaceGroupSnapshot.self, forKey: .group)
            self = .group(snapshot)
        }
    }
}
