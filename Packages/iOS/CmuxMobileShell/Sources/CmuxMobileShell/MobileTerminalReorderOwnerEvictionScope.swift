internal import CmuxMobileShellModel

/// Selects hierarchy owners that have crossed a Mac or account boundary.
enum MobileTerminalReorderOwnerEvictionScope {
    case owners(
        macDeviceIDs: Set<String>,
        presentationWorkspaceIDs: Set<MobileWorkspacePreview.ID>
    )
    case all

    var presentationWorkspaceIDs: Set<MobileWorkspacePreview.ID> {
        switch self {
        case let .owners(_, presentationWorkspaceIDs):
            return presentationWorkspaceIDs
        case .all:
            return []
        }
    }

    func contains(
        _ ownerIdentity: MobileWorkspaceOwnerIdentity,
        capturedOwnerIdentities: Set<MobileWorkspaceOwnerIdentity>
    ) -> Bool {
        switch self {
        case let .owners(macDeviceIDs, _):
            return capturedOwnerIdentities.contains(ownerIdentity)
                || ownerIdentity.ownerMacID.map(macDeviceIDs.contains) == true
        case .all:
            return true
        }
    }
}
