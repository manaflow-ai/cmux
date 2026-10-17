import CmuxSurfaceCatalogModel

/// Validates a saved Cloud terminal placement and an optional repaired tab.
public struct CloudTerminalAttachmentPlacementPolicy: Sendable {
    /// The resource and saved remote coordinates that identify the attachment.
    public let expectedResource: SurfaceResourceID
    /// The remote workspace recorded for the saved attachment, when present.
    public let expectedWorkspaceID: String?
    /// The remote tab recorded for the saved attachment, when present.
    public let expectedTabID: String?
    /// Whether a missing saved tab may be replaced in the saved workspace.
    public let allowsRepair: Bool

    /// Creates a placement policy for one restored or explicitly selected terminal.
    ///
    /// - Parameters:
    ///   - expectedResource: The terminal resource that owns the attachment.
    ///   - expectedWorkspaceID: The saved remote workspace, if known.
    ///   - expectedTabID: The saved remote tab, if known.
    ///   - allowsRepair: Whether a restored attachment may accept a replacement tab.
    public init(
        expectedResource: SurfaceResourceID,
        expectedWorkspaceID: String?,
        expectedTabID: String?,
        allowsRepair: Bool = false
    ) {
        self.expectedResource = expectedResource
        self.expectedWorkspaceID = expectedWorkspaceID
        self.expectedTabID = expectedTabID
        self.allowsRepair = allowsRepair
    }

    /// Validates the authoritative identity and returns the placement to adopt.
    ///
    /// `catalogPlacement` is the catalog's current view for the saved coordinates;
    /// it is nil when that view disappeared. A repaired placement is accepted only
    /// for an allowed restore and only in the saved remote workspace.
    public func validate(
        resourceID: SurfaceResourceID,
        remoteTabID: String?,
        catalogPlacement: SurfaceRemotePlacement?,
        materializedPlacement: SurfaceRemotePlacement?
    ) throws -> SurfaceRemotePlacement? {
        guard resourceID == expectedResource,
              remoteTabID == nil || expectedTabID == nil || remoteTabID == expectedTabID else {
            throw CloudDiagnosticFailure.placement
        }
        guard expectedWorkspaceID != nil || expectedTabID != nil else {
            return materializedPlacement
        }
        if let catalogPlacement {
            if let materializedPlacement, materializedPlacement != catalogPlacement {
                guard allowsRepair, materializedPlacement.workspaceID == catalogPlacement.workspaceID else {
                    throw CloudDiagnosticFailure.placement
                }
                return materializedPlacement
            }
            return materializedPlacement ?? catalogPlacement
        }
        guard allowsRepair else { throw CloudDiagnosticFailure.placement }
        // A restored tab may be repaired only when its saved workspace is known.
        // Without that boundary, a replacement from a fallback workspace could
        // silently rebind the pane to a different layout.
        guard expectedWorkspaceID != nil else { throw CloudDiagnosticFailure.placement }
        guard let materializedPlacement else { return nil }
        if let expectedWorkspaceID,
           materializedPlacement.workspaceID != expectedWorkspaceID {
            throw CloudDiagnosticFailure.placement
        }
        return materializedPlacement
    }
}
