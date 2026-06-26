import Foundation

/// How a Mac advertises itself to paired iOS devices. A strict single choice:
/// the Mac publishes exactly the chosen lane's attach routes, never a mix, so
/// switching modes changes how *every* phone reaches this Mac.
///
/// The user picks this during pairing/onboarding (and when adding a new Mac),
/// per `plans/feat-ios-iroh/DESIGN.md` "Production transport configuration".
public enum MobileTransportMode: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    /// iroh dial-by-EndpointId over the default cmux/n0 relay fleet. Zero setup,
    /// works off-LAN. The recommended default.
    case cmuxRelay

    /// iroh dial-by-EndpointId homed on a relay the user runs themselves
    /// (open-source `iroh-relay`), configured via `mobile.iOSIrohRelayURL`.
    case ownRelay

    /// TCP over the user's Tailscale tailnet / LAN. No relay dependency.
    case tailscale

    /// Stable identifier matching the stored raw value.
    public var id: String { rawValue }

    /// Whether this mode binds the iroh accept lane (true) or the TCP/Tailscale
    /// listener (false). Drives lane selection in `MobileHostService`.
    public var usesIroh: Bool {
        switch self {
        case .cmuxRelay, .ownRelay:
            return true
        case .tailscale:
            return false
        }
    }

    /// Localized label shown in the pairing picker and Settings.
    public var displayName: String {
        switch self {
        case .cmuxRelay:
            return String(
                localized: "settings.mobile.transportMode.cmuxRelay",
                defaultValue: "cmux relay (recommended)"
            )
        case .ownRelay:
            return String(
                localized: "settings.mobile.transportMode.ownRelay",
                defaultValue: "My own relay"
            )
        case .tailscale:
            return String(
                localized: "settings.mobile.transportMode.tailscale",
                defaultValue: "Tailscale"
            )
        }
    }
}
