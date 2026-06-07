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
        /// User-facing workspace title.
        public let title: String
        /// The workspace's current working directory, if reported.
        public let currentDirectory: String?
        /// Whether the Mac currently has this workspace selected.
        public let isSelected: Bool
        /// Whether this workspace is pinned, if the Mac reported it. `nil` when
        /// connected to a Mac old enough not to emit `is_pinned`.
        public let isPinned: Bool?
        /// Terminals belonging to this workspace.
        public let terminals: [Terminal]

        private enum CodingKeys: String, CodingKey {
            case id
            case title
            case currentDirectory = "current_directory"
            case isSelected = "is_selected"
            case isPinned = "is_pinned"
            case terminals
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
    /// Identifier of a workspace created by the request, if any.
    public let createdWorkspaceID: String?
    /// Identifier of a terminal created by the request, if any.
    public let createdTerminalID: String?

    private enum CodingKeys: String, CodingKey {
        case workspaces
        case createdWorkspaceID = "created_workspace_id"
        case createdTerminalID = "created_terminal_id"
    }

    /// Decode a workspace-list response from raw JSON data.
    /// - Parameter data: The RPC result payload.
    /// - Returns: The decoded response.
    /// - Throws: A decoding error if the payload is malformed.
    public static func decode(_ data: Data) throws -> MobileSyncWorkspaceListResponse {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
