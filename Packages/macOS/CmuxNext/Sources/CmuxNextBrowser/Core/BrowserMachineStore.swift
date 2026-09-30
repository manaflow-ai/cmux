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
    /// The proxy on 127.0.0.1 and this store's route credential.
    public var proxyPort: UInt16
    public var username: String
    public var password: String

    public init(machineKey: String, machineName: String, proxyPort: UInt16, username: String, password: String) {
        self.machineKey = machineKey
        self.machineName = machineName
        self.proxyPort = proxyPort
        self.username = username
        self.password = password
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
}
