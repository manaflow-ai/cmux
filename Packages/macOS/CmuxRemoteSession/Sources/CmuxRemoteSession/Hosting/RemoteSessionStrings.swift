/// User-facing connection-state strings the coordinator publishes, resolved
/// app-side so `String(localized:)` binds to the app bundle's localization
/// tables (the package never localizes). Keys and default values are
/// identical to the legacy controller's inline `String(localized:)` calls.
public struct RemoteSessionStrings: Sendable, Equatable {
    /// Format for the connected state of an SSH-only cloud VM whose proxy is
    /// disabled (`remote.state.connected.vmNoProxy`); `%@` is the display
    /// target.
    public let connectedVMNoProxyFormat: String
    /// Format for the suspended-auto-reconnect state detail
    /// (`remote.state.suspended.detail`); `%@` is the display target.
    public let suspendedDetailFormat: String

    /// Creates the strings bundle with both formats app-resolved.
    public init(connectedVMNoProxyFormat: String, suspendedDetailFormat: String) {
        self.connectedVMNoProxyFormat = connectedVMNoProxyFormat
        self.suspendedDetailFormat = suspendedDetailFormat
    }
}
