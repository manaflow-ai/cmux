public import Foundation

/// Stable workspace and surface identifiers carried by a selection event.
public struct SurfaceSelectionEventIdentity: Equatable, Sendable {
    /// Stable workspace UUID and protocol reference.
    public let workspaceId: UUID
    public let workspaceRef: String
    /// Stable surface UUID and protocol reference.
    public let surfaceId: UUID
    public let surfaceRef: String
    /// Optional containing pane UUID and protocol reference.
    public let paneId: UUID?
    public let paneRef: String?
    /// Optional containing window UUID and protocol reference.
    public let windowId: UUID?
    public let windowRef: String?

    public init(
        workspaceId: UUID,
        workspaceRef: String,
        surfaceId: UUID,
        surfaceRef: String,
        paneId: UUID? = nil,
        paneRef: String? = nil,
        windowId: UUID? = nil,
        windowRef: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.workspaceRef = workspaceRef
        self.surfaceId = surfaceId
        self.surfaceRef = surfaceRef
        self.paneId = paneId
        self.paneRef = paneRef
        self.windowId = windowId
        self.windowRef = windowRef
    }
}
