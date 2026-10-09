public import Foundation

/// Inputs of one phone-link host run that do not come from the account.
public struct MobileLinkHostOptions: Sendable {
    /// Advertised as the `_cmux._tcp` Bonjour name.
    public var macName: String
    public var appVersion: String
    public var appBuild: String
    /// B3 DEV switch: also accept WireGuard over WebRTC.
    public var wireGuardOverWebRTC: Bool
    public var keyDirectory: URL
    /// Files, git, browser, remote desktop, tunnels, simulators and tasks.
    public var services: MobileLinkServices

    public init(macName: String, appVersion: String, appBuild: String = "0", wireGuardOverWebRTC: Bool, keyDirectory: URL,
                services: MobileLinkServices = MobileLinkServices()) {
        self.services = services
        self.macName = macName
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.wireGuardOverWebRTC = wireGuardOverWebRTC
        self.keyDirectory = keyDirectory
    }
}
