public import CmuxNextBrowser
import CmuxNextRemoteLocalhost
public import Foundation

/// Which localhost a browser tab sees (plans/cmux-next/remote-localhost.md).
public enum RemoteLocalhostRoute: Equatable {
    /// The tab's machine is this Mac.
    case thisMac
    /// The tab's machine is `machine`, and its localhost is forwarded.
    case machine(String)
    /// The tab's machine is `machine`, but localhost is this Mac: the badge
    /// says so and names why.
    case thisMacInstead(String, RemoteLocalhostFallback)

    /// The remote machine's name, nil for this Mac.
    public var machineName: String? {
        switch self {
        case .thisMac: nil
        case .machine(let name), .thisMacInstead(let name, _): name
        }
    }
}

/// Which store a Chromium page of a tab uses (remote-localhost.md section 3).
public enum RemoteLocalhostStorePlan: Equatable {
    /// The browser profile's own store, with this navigation guard.
    case profile(BrowserNavigationGuard)
    /// The derived store (profile x machine) behind the proxy.
    case derived
    /// No page: an Open Desktop address no store here can show (it routes to no machine).
    /// Chromium's guard refuses it in the profile's store, so that store would reroute it forever.
    case blank

    /// A remote machine's loopback URL gets the derived store; any other URL
    /// of a remote tab stays in the profile's store and may not navigate to
    /// loopback. Tabs of this Mac, and remote tabs whose localhost is this Mac
    /// on purpose (update, turned off, WebKit), may go anywhere but an Open
    /// Desktop page, which reroutes to its machine's store (one that routes to none opens blank).
    public static func plan(route: RemoteLocalhostRoute, url: URL?) -> RemoteLocalhostStorePlan {
        guard case .machine = route else {
            return url.map(BrowserNavigationGuard.isCloudDesktop) == true ? .blank : .profile(.exceptCloudDesktop)
        }
        return url.flatMap(LoopbackHost.init(url:))?.isLoopback == true ? .derived : .profile(.noLoopback)
    }
}

public enum RemoteLocalhostFallback: Equatable {
    /// The machine's cmux-tui lacks `loopback-forward-v1`.
    case updateMachine
    /// `browser.remoteLocalhost` (or the workspace override) is off.
    case turnedOff
    /// WebKit tabs cannot forward: Network.framework never sends loopback
    /// destinations to a per-store proxy (remote-localhost.md section 7).
    case webKit
}
