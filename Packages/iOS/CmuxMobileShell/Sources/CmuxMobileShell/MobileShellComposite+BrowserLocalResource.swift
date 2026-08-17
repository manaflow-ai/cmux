public import CMUXMobileCore
import CmuxMobileRPC
import Foundation

@MainActor
extension MobileShellComposite {
    /// Creates a loader bound to the currently authenticated Mac and one
    /// workspace. The returned closure carries no filesystem path and can only
    /// request ranges through the authenticated browser RPC.
    /// - Parameter workspaceID: The Mac-local workspace identifier.
    /// - Returns: A local-resource loader when the host advertises support.
    public func makeMobileBrowserLocalResourceLoader(
        workspaceID: String
    ) -> MobileBrowserLocalResourceLoader? {
        guard supportsBrowserLocal, let client = remoteClient else { return nil }
        return MobileBrowserLocalResourceLoader { panelID, path, offset, length in
            try await client.fetchMobileBrowserLocalResource(
                panelID: panelID,
                workspaceID: workspaceID,
                path: path,
                offset: offset,
                length: length
            )
        }
    }
}
