import Foundation

/// Identifies the narrowest workspace, pane, or surface that owns a process.
struct CmuxTopProcessOwner: Hashable, Sendable {
    let workspaceID: UUID?
    let workspaceRef: String?
    let paneID: UUID?
    let paneRef: String?
    let surfaceID: UUID?
    let surfaceRef: String?
    let surfaceType: String?

    var specificity: Int {
        if surfaceID != nil || surfaceRef != nil {
            return 3
        }
        if paneID != nil || paneRef != nil {
            return 2
        }
        if workspaceID != nil || workspaceRef != nil {
            return 1
        }
        return 0
    }

    var identityKey: String? {
        if let surface = Self.identifier(id: surfaceID, ref: surfaceRef) {
            return "surface:\(surface)"
        }
        if let pane = Self.identifier(id: paneID, ref: paneRef) {
            return "pane:\(pane)"
        }
        if let workspace = workspaceIdentityKey {
            return "workspace:\(workspace)"
        }
        return nil
    }

    var workspaceIdentityKey: String? {
        Self.identifier(id: workspaceID, ref: workspaceRef)
    }

    func commonOwner(with other: CmuxTopProcessOwner) -> CmuxTopProcessOwner? {
        guard Self.identifiersMatch(
            lhsID: workspaceID,
            lhsRef: workspaceRef,
            rhsID: other.workspaceID,
            rhsRef: other.workspaceRef
        ) else {
            return nil
        }

        let workspaceID = workspaceID ?? other.workspaceID
        let workspaceRef = workspaceRef ?? other.workspaceRef
        if Self.identifiersMatch(
            lhsID: surfaceID,
            lhsRef: surfaceRef,
            rhsID: other.surfaceID,
            rhsRef: other.surfaceRef
        ), Self.identifiersAreCompatible(
            lhsID: paneID,
            lhsRef: paneRef,
            rhsID: other.paneID,
            rhsRef: other.paneRef
        ) {
            return CmuxTopProcessOwner(
                workspaceID: workspaceID,
                workspaceRef: workspaceRef,
                paneID: paneID ?? other.paneID,
                paneRef: paneRef ?? other.paneRef,
                surfaceID: surfaceID ?? other.surfaceID,
                surfaceRef: surfaceRef ?? other.surfaceRef,
                surfaceType: surfaceType ?? other.surfaceType
            )
        }
        if Self.identifiersMatch(
            lhsID: paneID,
            lhsRef: paneRef,
            rhsID: other.paneID,
            rhsRef: other.paneRef
        ) {
            return CmuxTopProcessOwner(
                workspaceID: workspaceID,
                workspaceRef: workspaceRef,
                paneID: paneID ?? other.paneID,
                paneRef: paneRef ?? other.paneRef,
                surfaceID: nil,
                surfaceRef: nil,
                surfaceType: nil
            )
        }
        return CmuxTopProcessOwner(
            workspaceID: workspaceID,
            workspaceRef: workspaceRef,
            paneID: nil,
            paneRef: nil,
            surfaceID: nil,
            surfaceRef: nil,
            surfaceType: nil
        )
    }

    private static func identifier(id: UUID?, ref: String?) -> String? {
        id?.uuidString ?? ref
    }

    private static func identifiersMatch(
        lhsID: UUID?,
        lhsRef: String?,
        rhsID: UUID?,
        rhsRef: String?
    ) -> Bool {
        if let lhsID, let rhsID {
            return lhsID == rhsID
        }
        if let lhsRef, let rhsRef {
            return lhsRef == rhsRef
        }
        return false
    }

    private static func identifiersAreCompatible(
        lhsID: UUID?,
        lhsRef: String?,
        rhsID: UUID?,
        rhsRef: String?
    ) -> Bool {
        let lhsExists = lhsID != nil || lhsRef != nil
        let rhsExists = rhsID != nil || rhsRef != nil
        guard lhsExists, rhsExists else { return true }
        return identifiersMatch(
            lhsID: lhsID,
            lhsRef: lhsRef,
            rhsID: rhsID,
            rhsRef: rhsRef
        )
    }
}
