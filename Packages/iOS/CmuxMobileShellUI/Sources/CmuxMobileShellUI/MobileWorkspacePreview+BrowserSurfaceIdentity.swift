import CmuxMobileBrowser
import CmuxMobileShellModel

extension MobileWorkspacePreview {
    /// Browser identity survives SwiftUI row-id scoping during multi-Mac aggregation.
    var browserSurfaceIdentity: BrowserWorkspaceIdentity {
        let remoteID = rpcWorkspaceID.rawValue
        guard let macDeviceID, !macDeviceID.isEmpty else {
            return BrowserWorkspaceIdentity(rawValue: remoteID)
        }
        let scopedID = "\(macDeviceID.utf8.count):\(macDeviceID):\(remoteID)"
        return BrowserWorkspaceIdentity(rawValue: scopedID, aliases: [remoteID])
    }

    /// Reconciliation is safe only after the owning Mac identity is known.
    var hasStableBrowserSurfaceIdentity: Bool {
        macDeviceID?.isEmpty == false
    }
}
