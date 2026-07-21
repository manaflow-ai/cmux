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
        /// The workspace's pane layout, or `nil` when absent or malformed.
        public let layout: Layout?

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
            case layout
        }

        /// Decodes a workspace while isolating optional layout decoding failures.
        /// - Parameter decoder: The decoder for one workspace object.
        /// - Throws: A decoding error when a required non-layout workspace field is malformed.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            windowID = try container.decodeIfPresent(String.self, forKey: .windowID)
            title = try container.decode(String.self, forKey: .title)
            currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory)
            isSelected = try container.decode(Bool.self, forKey: .isSelected)
            isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned)
            groupID = try container.decodeIfPresent(String.self, forKey: .groupID)
            preview = try container.decodeIfPresent(String.self, forKey: .preview)
            previewAt = try container.decodeIfPresent(Double.self, forKey: .previewAt)
            lastActivityAt = try container.decodeIfPresent(Double.self, forKey: .lastActivityAt)
            hasUnread = try container.decodeIfPresent(Bool.self, forKey: .hasUnread)
            terminals = try container.decode([Terminal].self, forKey: .terminals)
            layout = try? container.decode(Layout.self, forKey: .layout)
        }
    }

    /// A wire-level workspace pane layout snapshot.
    public struct Layout: Decodable, Sendable {
        /// A recursively decoded layout node.
        public indirect enum Node: Decodable, Sendable {
            /// A split branch with two child nodes.
            case split(Split)
            /// A leaf pane containing surface tabs.
            case pane(Pane)

            private enum CodingKeys: String, CodingKey {
                case kind
            }

            private enum Kind: String, Decodable {
                case split
                case pane
            }

            /// Decodes a layout node based on its `kind` discriminator.
            /// - Parameter decoder: The decoder for one layout node.
            /// - Throws: A decoding error for unknown kinds or malformed node data.
            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let kind = try container.decode(Kind.self, forKey: .kind)
                switch kind {
                case .split:
                    self = try .split(Split(from: decoder))
                case .pane:
                    self = try .pane(Pane(from: decoder))
                }
            }
        }

        /// A wire-level split branch.
        public struct Split: Decodable, Sendable {
            /// A split orientation emitted by bonsplit.
            public enum Orientation: String, Decodable, Sendable {
                /// Places children side by side.
                case horizontal
                /// Stacks children vertically.
                case vertical
            }

            /// The stable split identifier.
            public let id: String
            /// The axis along which this split divides its rectangle.
            public let orientation: Orientation
            /// The first child's proportional share.
            public let ratio: Double
            /// The first child node.
            public let first: Node
            /// The second child node.
            public let second: Node
        }

        /// A wire-level leaf pane.
        public struct Pane: Decodable, Sendable {
            /// The stable pane identifier.
            public let id: String
            /// The selected surface identifier, when one is selected.
            public let selectedSurfaceID: String?
            /// The pane's surfaces in tab order.
            public let surfaces: [Surface]

            private enum CodingKeys: String, CodingKey {
                case id
                case selectedSurfaceID = "selected_surface_id"
                case surfaces
            }
        }

        /// A wire-level surface tab.
        public struct Surface: Decodable, Sendable {
            /// The stable surface identifier.
            public let id: String
            /// The raw panel type emitted by the Mac.
            public let type: String
            /// The surface's display title.
            public let title: String
        }

        /// The Mac-side pane layout version.
        public let version: Int
        /// The focused pane identifier, when one is focused.
        public let focusedPaneID: String?
        /// The root of the recursive layout tree.
        public let root: Node

        private enum CodingKeys: String, CodingKey {
            case version
            case focusedPaneID = "focused_pane_id"
            case root
        }

        /// Memberwise construction for callers that assemble a row from an
        /// already-synced local source (mobile state sync v2 projects its
        /// record mirror through the same apply path as the wire response).
        public init(
            id: String,
            windowID: String?,
            title: String,
            currentDirectory: String?,
            isSelected: Bool,
            isPinned: Bool?,
            groupID: String?,
            preview: String?,
            previewAt: Double?,
            lastActivityAt: Double?,
            hasUnread: Bool?,
            terminals: [Terminal]
        ) {
            self.id = id
            self.windowID = windowID
            self.title = title
            self.currentDirectory = currentDirectory
            self.isSelected = isSelected
            self.isPinned = isPinned
            self.groupID = groupID
            self.preview = preview
            self.previewAt = previewAt
            self.lastActivityAt = lastActivityAt
            self.hasUnread = hasUnread
            self.terminals = terminals
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
            case anchorWorkspaceID = "anchor_workspace_id"
        }

        /// Memberwise construction for locally-synced sources (state sync v2).
        public init(
            id: String,
            name: String,
            isCollapsed: Bool,
            isPinned: Bool,
            anchorWorkspaceID: String
        ) {
            self.id = id
            self.name = name
            self.isCollapsed = isCollapsed
            self.isPinned = isPinned
            self.anchorWorkspaceID = anchorWorkspaceID
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

        /// Memberwise construction for locally-synced sources (state sync v2).
        public init(
            id: String,
            title: String,
            currentDirectory: String?,
            isFocused: Bool,
            isReady: Bool?
        ) {
            self.id = id
            self.title = title
            self.currentDirectory = currentDirectory
            self.isFocused = isFocused
            self.isReady = isReady
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

// Memberwise construction for callers that assemble a list response from an
// already-synced local source (mobile state sync v2 projects its record mirror
// through the same apply path the decoded wire response uses).
extension MobileSyncWorkspaceListResponse {
    /// Memberwise construction for locally-synced sources (state sync v2
    /// projects its record mirror through the same apply path).
    public init(
        workspaces: [Workspace],
        groups: [Group],
        createdWorkspaceID: String?,
        createdTerminalID: String?
    ) {
        self.workspaces = workspaces
        self.groups = groups
        self.createdWorkspaceID = createdWorkspaceID
        self.createdTerminalID = createdTerminalID
    }
}



