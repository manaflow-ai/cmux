public import Foundation

/// Typed decoder for the `workspace.list` / `mobile.workspace.list` RPC result.
///
/// The wire shape is snake_case (the Mac side of PR 5079 already emits it); the
/// `CodingKeys` map it onto camelCase Swift properties without changing the wire.
public struct MobileSyncWorkspaceListResponse: Decodable, Sendable {
    /// A workspace entry in the list response.
    public struct Workspace: Decodable, Sendable {
        /// Stable workspace identifier.
        public let id: String
        /// Stable Mac window identifier, when reported.
        public let windowID: String?
        /// User-facing workspace title.
        public let title: String
        /// The workspace's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the Mac currently has this workspace selected.
        public let isSelected: Bool
        /// Whether this workspace is pinned, if the Mac reported it. `nil` when
        /// connected to a Mac old enough not to emit `is_pinned`.
        public let isPinned: Bool?
        /// The id of the group this workspace belongs to, if any. `nil` for
        /// ungrouped workspaces and for Macs old enough not to emit groups.
        public let groupID: String?
        /// A one-line, plain-text preview of the most recent activity (the latest
        /// notification body/title), shown under the row like an iMessage preview.
        /// `nil` when the workspace has no activity or the Mac is old enough not to
        /// emit it.
        public let preview: String?
        /// Unix epoch seconds of the preview's activity, for the row's relative
        /// time. `nil` when there is no preview.
        public let previewAt: Double?
        /// Unix epoch seconds of the workspace's last activity. The Mac stamps
        /// this on every workspace (latest notification, falling back to the
        /// workspace's creation/connect time). `nil` on Macs old enough not to
        /// emit it.
        public let lastActivityAt: Double?
        /// Whether the workspace has unread activity on the Mac. `nil` on Macs
        /// old enough not to emit it (the row then shows no unread dot).
        public let hasUnread: Bool?
        /// Terminals belonging to this workspace.
        public let terminals: [Terminal]

        private enum CodingKeys: String, CodingKey {
            case id
            case windowID = "window_id"
            case title
            case currentDirectory = "current_directory"
            case isSelected = "is_selected"
            case isPinned = "is_pinned"
            case groupID = "group_id"
            case preview
            case previewAt = "preview_at"
            case lastActivityAt = "last_activity_at"
            case hasUnread = "has_unread"
            case terminals
        }
    }

    /// A workspace group section in the list response. Mirrors the iOS-facing
    /// subset the Mac emits (no v2 handle refs, color, or icon). Members are
    /// listed in the Mac's spatial (`tabs`) order. Absent on Macs old enough not
    /// to emit groups.
    public struct Group: Decodable, Sendable {
        /// Stable group identifier.
        public let id: String
        /// User-facing group name (shown as the section header label).
        public let name: String
        /// Whether the group is currently collapsed on the Mac.
        public let isCollapsed: Bool
        /// Whether the group is pinned on the Mac.
        public let isPinned: Bool
        /// The parent group id when this group is nested under another group.
        public let parentGroupID: String?
        /// The anchor workspace that owns this group. It is represented by the
        /// group header and never rendered as a separate row.
        public let anchorWorkspaceID: String

        // The Mac also emits `member_workspace_ids`, but membership is derived on
        // the client from each workspace's `group_id` (which preserves spatial
        // order), so the explicit member list is intentionally not decoded here.

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case isCollapsed = "is_collapsed"
            case isPinned = "is_pinned"
            case parentGroupID = "parent_group_id"
            case anchorWorkspaceID = "anchor_workspace_id"
        }
    }

    /// A terminal entry within a workspace.
    public struct Terminal: Decodable, Sendable {
        /// Stable terminal identifier.
        public let id: String
        /// User-facing terminal title.
        public let title: String
        /// The terminal's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the terminal currently holds focus.
        public let isFocused: Bool
        /// Whether the terminal surface is ready, if reported.
        public let isReady: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isFocused = "is_focused"
            case isReady = "is_ready"
        }
    }

    /// The full workspace list.
    public let workspaces: [Workspace]
    /// Group sections, in section order. Empty on Macs old enough not to emit
    /// groups (the field is decoded with `decodeIfPresent`).
    public let groups: [Group]
    /// Identifier of a workspace created by the request, if any.
    public let createdWorkspaceID: String?
    /// Identifier of a terminal created by the request, if any.
    public let createdTerminalID: String?

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case groups
        case createdWorkspaceID = "created_workspace_id"
        case createdTerminalID = "created_terminal_id"
    }

    /// Decodes a workspace-list response, defaulting `groups` to empty so a Mac
    /// old enough not to emit the field still decodes (the grouped UI then stays
    /// flat). `created_workspace_id` / `created_terminal_id` are optional.
    /// - Parameter decoder: The decoder for the RPC result payload.
    /// - Throws: A decoding error if `workspaces` is missing or malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decode([Workspace].self, forKey: .workspaces)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups) ?? []
        createdWorkspaceID = try container.decodeIfPresent(String.self, forKey: .createdWorkspaceID)
        createdTerminalID = try container.decodeIfPresent(String.self, forKey: .createdTerminalID)
    }

    /// Decode a workspace-list response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncWorkspaceListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
