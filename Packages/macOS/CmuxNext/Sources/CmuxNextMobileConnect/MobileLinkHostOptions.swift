public import Foundation

/// Inputs of one phone-link host run that do not come from the account.
public struct MobileLinkHostOptions: Sendable {
    /// Advertised as the `_cmux._tcp` Bonjour name.
    public var macName: String
    public var appVersion: String
    /// B3 DEV switch: also accept WireGuard over WebRTC.
    public var wireGuardOverWebRTC: Bool
    public var keyDirectory: URL

    public init(macName: String, appVersion: String, wireGuardOverWebRTC: Bool, keyDirectory: URL) {
        self.macName = macName
        self.appVersion = appVersion
        self.wireGuardOverWebRTC = wireGuardOverWebRTC
        self.keyDirectory = keyDirectory
    }
}
