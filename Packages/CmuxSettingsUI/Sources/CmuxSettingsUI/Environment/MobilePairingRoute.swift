import Foundation

/// One network address the iOS app can use to reach this Mac, shown in the
/// Mobile settings diagnostics.
///
/// The host derives these from the live pairing listener (typically the
/// machine's Tailscale addresses, plus a loopback route in debug builds) and
/// hands them to the settings UI through ``SettingsHostActions`` as part of a
/// ``MobilePairingStatusSnapshot``. The settings package stays Foundation-only,
/// so the host pre-formats the route rather than exposing its own transport
/// types.
public struct MobilePairingRoute: Sendable, Equatable, Identifiable {
    /// Stable identifier for the route (e.g. `"tailscale"`, `"tailscale_2"`,
    /// `"debug_loopback"`), used as the SwiftUI list identity.
    public let id: String

    /// Human-readable transport label, already localized by the host
    /// (e.g. "Tailscale", "Loopback").
    public let kindLabel: String

    /// The host or IP address the phone connects to.
    public let host: String

    /// The TCP port the phone connects to.
    public let port: Int

    /// Creates a pairing-route descriptor.
    ///
    /// - Parameters:
    ///   - id: Stable identifier used as the list identity.
    ///   - kindLabel: Localized transport label.
    ///   - host: Host or IP address the phone connects to.
    ///   - port: TCP port the phone connects to.
    public init(id: String, kindLabel: String, host: String, port: Int) {
        self.id = id
        self.kindLabel = kindLabel
        self.host = host
        self.port = port
    }

    /// The `host:port` pair as a single display string (e.g. `100.64.0.1:58465`).
    public var endpoint: String {
        "\(host):\(port)"
    }
}
