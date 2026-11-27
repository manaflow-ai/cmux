public import Foundation

/// The derived store of a remote-localhost tab (plans/cmux-next/
/// remote-localhost.md section 3): browser profile x machine, used only
/// while the tab's main frame is a loopback origin of a remote machine.
/// Every request of that store goes through the app's in-process proxy,
/// which sends loopback destinations to the machine.
public nonisolated struct BrowserMachineStore: Hashable, Sendable {
    /// 16 lowercase hex digits naming the machine (a hash of its daemon
    /// `registry_id`); part of the store's directory name.
    public var machineKey: String
    /// Shown in the badge and error pages (`build-box`).
    public var machineName: String
    /// The machine's proxy listener on 127.0.0.1. It accepts only this app
    /// and its Chromium helpers, so no credential is needed.
    public var proxyPort: UInt16

    public init(machineKey: String, machineName: String, proxyPort: UInt16) {
        self.machineKey = machineKey
        self.machineName = machineName
        self.proxyPort = proxyPort
    }
}

/// Which main-frame navigations a tab's store may hold. A violation is
/// cancelled and reported as `BrowserTabIntent.rerouteStore`.
public nonisolated enum BrowserNavigationGuard: Int32, Hashable, Sendable {
    /// Any URL (a tab whose machine is this Mac).
    case none = 0
    /// Only loopback web URLs (the derived store of a remote machine).
    case loopbackOnly = 1
    /// No loopback web URLs (a normal store in a remote workspace), so this
    /// Mac's localhost is never reached silently.
    case noLoopback = 2
    /// Any URL but an Open Desktop page (`*.cloud-desktop.localhost`): a tab of
    /// this Mac that goes there reroutes to that machine's store, never this Mac's
    /// loopback.
    case exceptCloudDesktop = 3

    /// The host suffix of an Open Desktop page: `<machine id>.cloud-desktop.localhost`.
    public static let cloudDesktopHostSuffix = ".cloud-desktop.localhost"

    /// Whether `url` is an Open Desktop page. Only a Chromium tab can show one (through the app's
    /// Cloud tunnel); anywhere else it would be this Mac's own loopback, so WebKit refuses it.
    /// Matches the CEF shim's `IsCloudDesktopHost` (any case, a trailing dot dropped), so the two
    /// never disagree about a page.
    public static func isCloudDesktop(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasSuffix(".") { host.removeLast() }
        return host.count > cloudDesktopHostSuffix.count && host.hasSuffix(cloudDesktopHostSuffix)
    }
}
