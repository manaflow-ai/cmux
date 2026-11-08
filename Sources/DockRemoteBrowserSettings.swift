import Foundation
import CmuxCore

/// Remote-workspace browser settings the Dock forwards to `BrowserPanel`, so
/// Dock browsers route through the same remote proxy / website-data store as
/// main-area browser panes instead of navigating locally on a remote/cloud
/// workspace.
struct DockRemoteBrowserSettings: Sendable {
    let proxyEndpoint: BrowserProxyEndpoint?
    let bypassRemoteProxy: Bool
    let isRemoteWorkspace: Bool
    let remoteWebsiteDataStoreIdentifier: UUID?
    let remoteStatus: BrowserRemoteWorkspaceStatus?

    static let local = DockRemoteBrowserSettings(
        proxyEndpoint: nil,
        bypassRemoteProxy: false,
        isRemoteWorkspace: false,
        remoteWebsiteDataStoreIdentifier: nil,
        remoteStatus: nil
    )
}
