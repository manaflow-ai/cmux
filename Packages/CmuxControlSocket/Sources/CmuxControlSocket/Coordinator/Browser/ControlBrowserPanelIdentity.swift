public import Foundation

/// The resolved workspace/surface identity a successful browser-surface
/// resolution carries back to the coordinator (which mints the matching
/// `workspace_ref`/`surface_ref` for the payload).
public struct ControlBrowserPanelIdentity: Sendable, Equatable {
    /// The owning workspace id.
    public let workspaceID: UUID
    /// The resolved browser surface id.
    public let surfaceID: UUID

    /// Creates a panel identity.
    ///
    /// - Parameters:
    ///   - workspaceID: The owning workspace id.
    ///   - surfaceID: The resolved browser surface id.
    public init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }
}
