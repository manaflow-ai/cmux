import CmuxNextBrowser
import CmuxNextRemoteLocalhost
import Foundation

/// Which localhost a browser tab sees (plans/cmux-next/remote-localhost.md).
enum RemoteLocalhostRoute: Equatable {
    /// The tab's machine is this Mac.
    case thisMac
    /// The tab's machine is `machine`, and its localhost is forwarded.
    case machine(String)
    /// The tab's machine is `machine`, but localhost is this Mac: the badge
    /// says so and names why.
    case thisMacInstead(String, RemoteLocalhostFallback)

    /// The remote machine's name, nil for this Mac.
    var machineName: String? {
        switch self {
        case .thisMac: nil
        case .machine(let name), .thisMacInstead(let name, _): name
        }
    }
}

/// Which store a Chromium page of a tab uses (remote-localhost.md section 3).
enum RemoteLocalhostStorePlan: Equatable {
    /// The browser profile's own store, with this navigation guard.
    case profile(BrowserNavigationGuard)
    /// The derived store (profile x machine) behind the proxy.
    case derived

    /// A remote machine's loopback URL gets the derived store; any other URL
    /// of a remote tab stays in the profile's store and may not navigate to
    /// loopback. Tabs of this Mac, and remote tabs whose localhost is this Mac
    /// on purpose (update, turned off, WebKit), are unrestricted.
    static func plan(route: RemoteLocalhostRoute, url: URL?) -> RemoteLocalhostStorePlan {
        guard case .machine = route else { return .profile(.none) }
        return url.map(LoopbackHost.isLoopback(url:)) == true ? .derived : .profile(.noLoopback)
    }
}

enum RemoteLocalhostFallback: Equatable {
    /// The machine's cmux-tui lacks `loopback-forward-v1`.
    case updateMachine
    /// `browser.remoteLocalhost` (or the workspace override) is off.
    case turnedOff
    /// WebKit tabs do not forward yet (stage 4).
    case webKit
}
