import Foundation

/// The cmux workspace/pane/surface a process tree is attributed to in the
/// `system.memory` diagnostic payload, plus the reason for that attribution.
public struct CmuxTopProcessAttribution: Hashable, Sendable {
    /// The owning workspace, if known.
    public let workspaceID: UUID?
    /// The owning workspace ref, if known.
    public let workspaceRef: String?
    /// The owning pane, if known.
    public let paneID: UUID?
    /// The owning pane ref, if known.
    public let paneRef: String?
    /// The owning surface, if known.
    public let surfaceID: UUID?
    /// The owning surface ref, if known.
    public let surfaceRef: String?
    /// The owning surface type, if known.
    public let surfaceType: String?
    /// Why the process tree was attributed here.
    public let reason: String

    /// Creates a process attribution.
    public init(
        workspaceID: UUID?,
        workspaceRef: String?,
        paneID: UUID?,
        paneRef: String?,
        surfaceID: UUID?,
        surfaceRef: String?,
        surfaceType: String?,
        reason: String
    ) {
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.paneID = paneID
        self.paneRef = paneRef
        self.surfaceID = surfaceID
        self.surfaceRef = surfaceRef
        self.surfaceType = surfaceType
        self.reason = reason
    }

    /// The attribution's wire payload.
    public func payload() -> [String: Any] {
        [
            "workspace_id": workspaceID?.uuidString as Any? ?? NSNull(),
            "workspace_ref": workspaceRef as Any? ?? NSNull(),
            "pane_id": paneID?.uuidString as Any? ?? NSNull(),
            "pane_ref": paneRef as Any? ?? NSNull(),
            "surface_id": surfaceID?.uuidString as Any? ?? NSNull(),
            "surface_ref": surfaceRef as Any? ?? NSNull(),
            "surface_type": surfaceType as Any? ?? NSNull(),
            "reason": reason
        ]
    }
}
