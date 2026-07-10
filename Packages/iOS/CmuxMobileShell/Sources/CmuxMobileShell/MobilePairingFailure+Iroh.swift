internal import CmuxMobileSupport
internal import CmuxMobileTransport

extension MobilePairingFailureCategory {
    var irohMessage: String? {
        switch self {
        case .irohMacUnreachable:
            return L10n.string(
                "mobile.pairing.irohMacUnavailable",
                defaultValue: "Could not reach this Mac over Iroh. Make sure cmux is open on the Mac and it is awake, then try again."
            )
        case .irohTimedOut:
            return L10n.string(
                "mobile.pairing.irohTimedOut",
                defaultValue: "Iroh did not get a response from this Mac in time. Make sure the Mac is awake and online, then try again."
            )
        case .irohSecureChannelFailed:
            return L10n.string(
                "mobile.pairing.irohSecureChannelFailed",
                defaultValue: "Iroh could not verify the secure connection to this Mac. Trust the Mac again before connecting."
            )
        case .irohEndpointChanged:
            return L10n.string(
                "mobile.pairing.irohEndpointChanged",
                defaultValue: "This Mac's Iroh identity changed. Trust it again from the Mac before sending account credentials."
            )
        case .irohConnectionDropped:
            return L10n.string(
                "mobile.pairing.irohConnectionDropped",
                defaultValue: "Connected to this Mac over Iroh, but the connection closed before pairing finished."
            )
        default:
            return nil
        }
    }

    var irohGuidance: String? {
        switch self {
        case .irohMacUnreachable, .irohTimedOut, .irohConnectionDropped:
            return L10n.string(
                "mobile.pairing.guidance.irohReachability",
                defaultValue: "No Tailscale setup is needed for Iroh. Keep cmux open on the Mac and make sure both devices are online."
            )
        case .irohSecureChannelFailed, .irohEndpointChanged:
            return L10n.string(
                "mobile.pairing.guidance.irohRetrust",
                defaultValue: "Open cmux on the Mac and trust this phone again before retrying."
            )
        default:
            return nil
        }
    }

    static func classifyIroh(error: any Error, host: String?, port: Int?) -> MobilePairingFailureCategory? {
        guard let irohError = error as? CmxIrohByteTransportError else { return nil }
        switch irohError {
        case let .connectionFailed(_, kind),
             let .endpointBindFailed(_, kind):
            switch kind {
            case .timedOut:
                return .irohTimedOut
            case .secureChannelFailed:
                return .irohSecureChannelFailed
            case .connectionRefused, .hostUnreachable, .dnsFailed, .permissionDenied, .generic:
                return .irohMacUnreachable
            }
        case .receiveFailed, .sendFailed, .alreadyClosed, .notConnected:
            return .irohConnectionDropped
        case .emptyPeerID, .invalidMaximumReceiveLength,
             .unsupportedRouteKind, .unsupportedEndpoint:
            return .unknown(host: host, port: port)
        }
    }
}
