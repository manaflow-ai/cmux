import Foundation

/// Records a process owner together with the evidence used to infer it.
struct CmuxTopProcessAttribution: Hashable, Sendable {
    let workspaceID: UUID?
    let workspaceRef: String?
    let paneID: UUID?
    let paneRef: String?
    let surfaceID: UUID?
    let surfaceRef: String?
    let surfaceType: String?
    let reason: String

    init(
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

    init(owner: CmuxTopProcessOwner, reason: String) {
        self.init(
            workspaceID: owner.workspaceID,
            workspaceRef: owner.workspaceRef,
            paneID: owner.paneID,
            paneRef: owner.paneRef,
            surfaceID: owner.surfaceID,
            surfaceRef: owner.surfaceRef,
            surfaceType: owner.surfaceType,
            reason: reason
        )
    }

    var owner: CmuxTopProcessOwner {
        CmuxTopProcessOwner(
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: paneID,
            paneRef: paneRef,
            surfaceID: surfaceID,
            surfaceRef: surfaceRef,
            surfaceType: surfaceType
        )
    }

    func payload() -> [String: Any] {
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
