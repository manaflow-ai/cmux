public import Foundation

/// Workspace / pane / surface attribution for a Task Manager memory group,
/// parsed from a `top_attribution` payload. `nil` when the payload is absent
/// or carries no identifying field.
public struct CmuxTaskManagerMemoryAttribution: Sendable {
    /// Attributed workspace UUID, when known.
    public let workspaceId: UUID?
    /// Attributed workspace ref string, when known.
    public let workspaceRef: String?
    /// Attributed pane UUID, when known.
    public let paneId: UUID?
    /// Attributed pane ref string, when known.
    public let paneRef: String?
    /// Attributed surface UUID, when known.
    public let surfaceId: UUID?
    /// Attributed surface ref string, when known.
    public let surfaceRef: String?
    /// Attributed surface type string, when known.
    public let surfaceType: String?

    public init?(_ payload: [String: Any]?) {
        guard let payload else { return nil }
        let reader = TaskManagerJSONPayloadReader(payload)
        self.workspaceId = reader.uuid("workspace_id")
        self.workspaceRef = reader.string("workspace_ref")
        self.paneId = reader.uuid("pane_id")
        self.paneRef = reader.string("pane_ref")
        self.surfaceId = reader.uuid("surface_id")
        self.surfaceRef = reader.string("surface_ref")
        self.surfaceType = reader.string("surface_type")
        if workspaceId == nil,
           workspaceRef == nil,
           paneId == nil,
           paneRef == nil,
           surfaceId == nil,
           surfaceRef == nil,
           surfaceType == nil {
            return nil
        }
    }
}
