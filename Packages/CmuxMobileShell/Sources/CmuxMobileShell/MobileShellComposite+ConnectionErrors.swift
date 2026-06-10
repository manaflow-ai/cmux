public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog


// MARK: - Connection error mapping
extension MobileShellComposite {
    func disconnectForAuthorizationFailureIfNeeded(_ error: any Error) -> Bool {
        guard Self.shouldDisconnectForAuthorizationFailure(error) else {
            return false
        }
        connectionError = Self.localizedConnectionError(for: error, route: activeRoute)
        connectionRequiresReauth = true
        connectionState = .disconnected
        macConnectionStatus = .unavailable
        clearRemoteConnectionContext()
        return true
    }

    private static func shouldDisconnectForAuthorizationFailure(_ error: any Error) -> Bool {
        guard let connectionError = error as? MobileShellConnectionError else {
            return false
        }
        switch connectionError {
        case .attachTicketExpired, .authorizationFailed, .accountMismatch, .insecureManualRoute:
            return true
        case let .rpcError(code, message):
            let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let normalizedCode,
               ["unauthorized", "forbidden", "invalid_token", "token_expired", "expired_token", "auth_required"].contains(normalizedCode) {
                return true
            }
            let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalizedMessage.contains("unauthorized")
                || normalizedMessage.contains("forbidden")
                || normalizedMessage.contains("invalid token")
                || normalizedMessage.contains("expired token")
                || normalizedMessage.contains("token expired")
        case .invalidResponse, .connectionClosed, .requestTimedOut:
            return false
        }
    }

    static func localizedConnectionError(for error: any Error, route: CmxAttachRoute? = nil) -> String {
        let hostPort = route.flatMap(Self.hostPortDescription(for:))
        if let networkError = error as? CmxNetworkByteTransportError {
            switch networkError {
            case .connectionTimedOut:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectTimedOutFormat",
                    defaultValue: "No response from %@:%d. Your Mac may be asleep or off Tailscale. Make sure it's awake and on the same Tailscale network.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case let .connectionFailed(_, kind):
                switch kind {
                case .connectionRefused:
                    return L10n.string(
                        "mobile.pairing.appNotRunning",
                        defaultValue: "Your Mac is reachable, but cmux isn't running there (or mobile pairing is off). Open cmux on the Mac, then try again."
                    )
                case .permissionDenied:
                    return L10n.string(
                        "mobile.pairing.localNetworkPermission",
                        defaultValue: "iOS blocked the connection. Allow cmux to use the Local Network in iOS Settings, then try again."
                    )
                case .hostUnreachable:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.hostUnreachableFormat",
                        defaultValue: "Can't reach %@:%d. Make sure your Mac is awake and on the same Tailscale network as this device.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                case .dnsFailed:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.dnsFailedFormat",
                        defaultValue: "Couldn't resolve %@. Check that Tailscale is connected on both devices.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                case .timedOut, .secureChannelFailed, .generic:
                    return localizedHostPortConnectionError(
                        key: "mobile.pairing.connectionFailedFormat",
                        defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                        fallbackKey: "mobile.pairing.runtimeUnavailable",
                        fallbackDefaultValue: "Could not connect to your computer.",
                        hostPort: hostPort
                    )
                }
            case .notConnected, .alreadyClosed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionFailedFormat",
                    defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .receiveFailed, .sendFailed:
                return localizedHostPortConnectionError(
                    key: "mobile.pairing.connectionDroppedFormat",
                    defaultValue: "Connected to %@:%d, but the host closed the connection. Check that the host app is still running.",
                    fallbackKey: "mobile.pairing.runtimeUnavailable",
                    fallbackDefaultValue: "Could not connect to your computer.",
                    hostPort: hostPort
                )
            case .emptyHost, .invalidPort, .invalidMaximumReceiveLength, .unsupportedRouteKind, .unsupportedEndpoint, .receiveAlreadyInProgress, .sendAlreadyInProgress:
                break
            }
        }
        guard let connectionError = error as? MobileShellConnectionError else {
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
        switch connectionError {
        case .requestTimedOut:
            return localizedHostPortConnectionError(
                key: "mobile.pairing.connectionTimedOutFormat",
                defaultValue: "No response from %@:%d. Make sure the host app is open and accepting mobile connections.",
                fallbackKey: "mobile.pairing.requestTimedOut",
                fallbackDefaultValue: "The computer did not respond. Check the host and port, then try again.",
                hostPort: hostPort
            )
        case .insecureManualRoute:
            return L10n.string("mobile.pairing.secureRouteRequired", defaultValue: "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer.")
        case .attachTicketExpired:
            return L10n.string("mobile.pairing.attachTicketExpired", defaultValue: "This pairing link expired. Pair again with a fresh QR/link from that computer.")
        case .authorizationFailed:
            return L10n.string("mobile.pairing.authorizationFailed", defaultValue: "Couldn't verify your account with this Mac. Make sure both devices use the same cmux account and a matching build (both release, or both development), then try again.")
        case .accountMismatch:
            return L10n.string("mobile.pairing.accountMismatch", defaultValue: "This Mac is signed in to a different cmux account. Sign out and sign back in with the account that owns this Mac.")
        case .invalidResponse, .connectionClosed, .rpcError:
            return L10n.string("mobile.pairing.runtimeUnavailable", defaultValue: "Could not connect to your computer.")
        }
    }

    /// Maps a connect error to the `ios_pairing_failed` `reason` enum (sizes and
    /// enums only — never the underlying error text). Falls back to `network` for
    /// transport drops and `other` for anything unrecognized.
    static func pairingFailureReason(for error: any Error) -> String {
        if let connectionError = error as? MobileShellConnectionError {
            switch connectionError {
            case .attachTicketExpired: return "ticket_expired"
            case .authorizationFailed: return "auth"
            case .accountMismatch: return "account_mismatch"
            case .insecureManualRoute: return "unsupported_route"
            case .requestTimedOut: return "timeout"
            case .invalidResponse, .connectionClosed, .rpcError: return "network"
            }
        }
        if error is CancellationError { return "cancelled" }
        return "other"
    }

    private static func localizedHostPortConnectionError(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        fallbackKey: StaticString,
        fallbackDefaultValue: String.LocalizationValue,
        hostPort: (host: String, port: Int)?
    ) -> String {
        guard let hostPort else {
            return L10n.string(fallbackKey, defaultValue: fallbackDefaultValue)
        }
        return String(
            format: L10n.string(key, defaultValue: defaultValue),
            hostPort.host,
            hostPort.port
        )
    }

    private static func hostPortDescription(for route: CmxAttachRoute) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return (host, port)
    }

}
