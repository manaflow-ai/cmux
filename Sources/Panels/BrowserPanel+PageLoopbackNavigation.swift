import CmuxCore
import Foundation

extension BrowserPanel {
    /// How a page-initiated navigation to loopback reaches its service.
    enum PageLoopbackNavigationRoute: Equatable {
        /// Let WebKit load the request as it asked.
        case allow
        /// Cancel WebKit's load and replay the request through the panel's
        /// own navigation, which takes the same remote loopback route a typed
        /// or opened loopback URL takes.
        case remote
        /// Cancel the load: the remote route cannot carry it, and this Mac's
        /// loopback must not serve it.
        case block
    }

    /// Routes a server redirect, `location` change, link or frame load whose
    /// target is loopback. In a remote workspace that loopback belongs to the
    /// remote host, so WebKit must never resolve it against this Mac.
    ///
    /// Local workspaces, panes on a cloud route, and URLs the current SSH
    /// loopback route already owns are left to WebKit.
    func pageLoopbackNavigationRoute(to url: URL, isMainFrame: Bool) -> PageLoopbackNavigationRoute {
        guard usesRemoteWorkspaceProxy,
              cloudBrowserMachineID == nil,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              RemoteLoopbackProxyAlias.isLoopbackHost(url.host ?? ""),
              !cloudAccess.owns(url) else {
            return .allow
        }
        // A frame cannot be moved onto the pane-wide remote route.
        guard isMainFrame else { return .block }
        // The legacy proxy route rewrites only plain HTTP loopback to its alias;
        // replaying HTTPS would load this Mac's loopback and return here.
        if remoteProxyEndpoint != nil, scheme == "https" { return .block }
        return .remote
    }
}
