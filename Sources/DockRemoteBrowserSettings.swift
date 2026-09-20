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
    /// Mirrors `BrowserPanel.init`'s `routesThroughRemoteProxy` — broader than
    /// `isRemoteWorkspace`, since an ssh-tmux mirror workspace routes its
    /// Dock browsers through the mirror's proxy without being
    /// `isRemoteWorkspace`. Without this, a Dock browser panel in a mirror
    /// workspace would fall back to the shared local website-data store
    /// while still receiving the mirror's proxy endpoint broadcasts,
    /// silently routing every other local browser on that store through it.
    let routesThroughRemoteProxy: Bool

    static let local = DockRemoteBrowserSettings(
        proxyEndpoint: nil,
        bypassRemoteProxy: false,
        isRemoteWorkspace: false,
        remoteWebsiteDataStoreIdentifier: nil,
        remoteStatus: nil,
        routesThroughRemoteProxy: false
    )
}
