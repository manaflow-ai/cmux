public import Foundation

/// Current Mac focus target for mobile Voice Mode.
public struct MobileFocusSnapshot: Codable, Equatable, Sendable {
    /// Focused workspace id, if any.
    public let workspaceID: String?
    /// Short workspace reference, if any.
    public let workspaceRef: String?
    /// Focused workspace title, if any.
    public let workspaceTitle: String?
    /// Focused surface id, if any.
    public let surfaceID: String?
    /// Short surface reference, if any.
    public let surfaceRef: String?
    /// Focused surface title, if any.
    public let surfaceTitle: String?
    /// Focused surface type, if known.
    public let surfaceType: String?
    /// Whether the focused surface is a terminal.
    public let isTerminal: Bool

    private enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case workspaceRef = "workspace_ref"
        case workspaceTitle = "workspace_title"
        case surfaceID = "surface_id"
        case surfaceRef = "surface_ref"
        case surfaceTitle = "surface_title"
        case surfaceType = "surface_type"
        case isTerminal = "is_terminal"
    }

    /// Creates a focus snapshot.
    public init(
        workspaceID: String?,
        workspaceRef: String?,
        workspaceTitle: String?,
        surfaceID: String?,
        surfaceRef: String?,
        surfaceTitle: String?,
        surfaceType: String?,
        isTerminal: Bool
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.workspaceTitle = workspaceTitle
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.surfaceTitle = surfaceTitle
        self.surfaceType = surfaceType
        self.isTerminal = isTerminal
    }

    /// Decode a snapshot from raw RPC/event JSON.
    /// - Parameter data: JSON object data.
    /// - Returns: The decoded focus snapshot.
    public static func decode(_ data: Data) throws -> MobileFocusSnapshot {
        try JSONDecoder().decode(Self.self, from: data)
    }
}
