import CMUXMobileCore
import CmuxMobileSupport

/// Localized copy for a pinned transport-mode failure.
///
/// The core error remains transport-layer and locale-independent; this iOS
/// boundary owns the actionable wording shown below the connection status.
extension CmxTransportModeError {
    @MainActor
    var mobileMessage: String {
        switch self {
        case let .noRoute(mode, macDisplayName):
            let format: String
            switch mode {
            case .lan:
                format = L10n.string(
                    "mobile.transportMode.noLANRoute",
                    defaultValue: "LAN only is selected, but no LAN route to %@ is available."
                )
            case .tailscale:
                format = L10n.string(
                    "mobile.transportMode.noTailscaleRoute",
                    defaultValue: "Tailscale only is selected, but no Tailscale route to %@ is available."
                )
            case .iroh:
                format = L10n.string(
                    "mobile.transportMode.noIrohRoute",
                    defaultValue: "iroh only is selected, but no iroh route to %@ is available."
                )
            case .automatic:
                format = L10n.string(
                    "mobile.transportMode.noRoute",
                    defaultValue: "No route to %@ is available."
                )
            case .direct:
                format = L10n.string(
                    "mobile.transportMode.noDirectRoute",
                    defaultValue: "Direct mode is selected, but no configured direct route to %@ is available."
                )
            }
            let target = macDisplayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackTarget = L10n.string(
                "mobile.transportMode.thisComputer",
                defaultValue: "this computer"
            )
            let displayTarget = target?.isEmpty == false ? target ?? fallbackTarget : fallbackTarget
            return String(format: format, displayTarget)
        case let .routeClassMismatch(expected, actual):
            return String(format: L10n.string(
                "mobile.transportMode.routeClassMismatch",
                defaultValue: "The selected %@ mode cannot use a %@ route."
            ), expected.displayName, actual.displayName)
        }
    }

    @MainActor
    var mobileGuidance: String {
        switch self {
        case let .noRoute(mode, _):
            switch mode {
            case .lan:
                return L10n.string(
                    "mobile.transportMode.guidance.lan",
                    defaultValue: "Put the iPhone and Mac on the same local network, make sure cmux is running, then retry."
                )
            case .tailscale:
                return L10n.string(
                    "mobile.transportMode.guidance.tailscale",
                    defaultValue: "Open Tailscale on both devices and confirm the Mac is advertising its Tailscale address, then retry."
                )
            case .iroh:
                return L10n.string(
                    "mobile.transportMode.guidance.iroh",
                    defaultValue: "Make sure both devices are signed in to the same cmux account and the Mac's iroh endpoint is online, then retry."
                )
            case .automatic:
                return L10n.string(
                    "mobile.transportMode.guidance.auto",
                    defaultValue: "Check that cmux is running on the Mac, then retry."
                )
            case .direct:
                return L10n.string(
                    "mobile.transportMode.guidance.direct",
                    defaultValue: "Enable a direct address for this computer or choose another transport mode."
                )
            }
        case .routeClassMismatch:
            return L10n.string(
                "mobile.transportMode.guidance.mismatch",
                defaultValue: "Change the transport mode or restore a route in the selected network."
            )
        }
    }
}
