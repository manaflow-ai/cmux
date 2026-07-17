import CmuxCore
import Foundation

/// Immutable selected-workspace state that can affect the window Dock.
struct WindowDockWorkspaceSnapshot: Equatable, Sendable {
    let configurationIdentity: DockConfigurationContext.Identity
    let proxyEndpoint: BrowserProxyEndpoint?
    let remoteStatus: BrowserRemoteWorkspaceStatus?
}
