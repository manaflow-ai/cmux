public import CMUXMobileCore
internal import CmuxMobileRPC
internal import CmuxMobileSupport
internal import CmuxMobileTransport
import Foundation

/// The distinct, user-visible outcomes a pairing attempt can fail with.
///
/// Pairing used to collapse every transport, ticket, and auth failure into one
/// opaque ~60s "could not connect" (or, when the error never reached the view,
/// a silent revert with no message at all). This enum is the single
/// classification of *why* an attempt failed so that one place owns the mapping
/// to the localized headline, the actionable guidance line, and the
/// `ios_pairing_failed` analytics reason. Every failed pairing path resolves to
/// exactly one category, so the UI always has a non-empty message to show.
///
/// The cases are pure value types and the mapping functions are pure, so the
/// whole "error -> what the user reads" contract is unit-testable without a live
/// connection. ``classify(error:route:)`` is the only entry point; it folds the
/// transport-level ``CmxNetworkByteTransportError``, the RPC-level
/// ``MobileShellConnectionError``, and cancellation into these categories.
public enum MobilePairingFailureCategory: Equatable, Sendable {
    /// The device has no network path at all (airplane mode / no Wi-Fi / no
    /// cellular). Caught by the reachability preflight before any connect, so it
    /// fails fast instead of waiting out the per-route timeouts.
    case offline
    /// Could not route to the Mac's address. The dominant real cause is the
    /// phone not being on the same Tailscale tailnet as the address the QR
    /// embedded, so the tailnet IP is simply unroutable.
    case hostUnreachable(host: String?, port: Int?)
    /// The address was reachable but nothing accepted the connection: cmux is not
    /// running on the Mac, or mobile pairing is off (it is off by default in
    /// Release).
    case listenerNotRunning(host: String?, port: Int?)
    /// iOS blocked the connection on Local Network privacy grounds.
    case localNetworkBlocked
    /// DNS could not resolve the host (a `.ts.net` MagicDNS name with Tailscale
    /// down on one side).
    case dnsFailed(host: String?, port: Int?)
    /// The TCP connection came up but the host handshake did not respond in time.
    case handshakeTimedOut(host: String?, port: Int?)
    /// Connected, then the host dropped the connection mid-handshake.
    case connectionDropped(host: String?, port: Int?)
    /// The Mac is signed in to a different cmux account than this device.
    case accountMismatch
    /// The pairing code was minted for a different email than this device.
    case emailMismatch(expected: String, actual: String?)
    /// The owner's account could not be verified with the Mac (stale/invalid
    /// token, or a release-vs-development build mismatch).
    case authFailed
    /// The QR's account binding (`ub`) cannot match because the two auth
    /// channels differ: this build signs in to cmux's development auth
    /// environment while the scanned URL's scheme declares a release-channel
    /// Mac (release Macs emit `cmux-ios`, #6038). Stack user ids are
    /// per-project, so a development-environment id never equals the
    /// production id a release Mac stamps into its QR — even for the same
    /// email. Telling the user to "sign in with the same email" would be
    /// wrong; the fix is rebuilding the phone app with production auth
    /// (`ios/scripts/reload.sh --prod-auth`) or pairing with a dev-channel
    /// Mac (https://github.com/manaflow-ai/cmux/issues/7145). A dev↔dev
    /// user-id mismatch is a genuine different-account failure and stays
    /// ``authFailed``.
    case authEnvironmentMismatch
    /// The pairing link/QR expired; a fresh one is needed.
    case ticketExpired
    /// The scanned/typed input was not a pairing QR cmux recognizes (malformed,
    /// not a cmux code, or an unreadable URL).
    case invalidCode
    /// The QR is a cmux pairing code, but it uses a grammar version newer than
    /// this build understands (the Mac is on a newer cmux). The fix is updating
    /// the phone app, not re-scanning.
    case unrecognizedVersion
    /// The scanned/pasted code only points back at the Mac itself (loopback),
    /// which the phone can never dial.
    case loopbackRejected
    /// The pairing code carried only an untrusted manual route that cannot carry
    /// the account credential.
    case unsupportedRoute
    /// The pairing code carried no route kind this device build can dial (for
    /// example an iroh-only ticket on a build without the iroh transport).
    case noSupportedRoute
    /// The attempt was cancelled (the user tapped Cancel, or a newer attempt
    /// superseded it). Not surfaced as an error.
    case cancelled
    /// Anything else: a still-actionable generic "could not connect".
    case unknown(host: String?, port: Int?)
}

extension MobilePairingFailureCategory {
    /// The compact `ios_pairing_failed` `reason` enum value (no error text, no
    /// host) for product analytics.
    public var analyticsReason: String {
        switch self {
        case .offline: return "offline"
        case .hostUnreachable: return "host_unreachable"
        case .listenerNotRunning: return "listener_not_running"
        case .localNetworkBlocked: return "local_network_blocked"
        case .dnsFailed: return "dns_failed"
        case .handshakeTimedOut: return "timeout"
        case .connectionDropped: return "connection_dropped"
        case .accountMismatch: return "account_mismatch"
        case .emailMismatch: return "email_mismatch"
        case .authFailed: return "auth"
        case .authEnvironmentMismatch: return "auth_environment_mismatch"
        case .ticketExpired: return "ticket_expired"
        case .invalidCode: return "invalid_code"
        case .unrecognizedVersion: return "unrecognized_version"
        case .loopbackRejected: return "loopback_rejected"
        case .unsupportedRoute: return "unsupported_route"
        case .noSupportedRoute: return "no_supported_route"
        case .cancelled: return "cancelled"
        case .unknown: return "other"
        }
    }

    /// Whether a definitive auth failure that should drive the re-auth prompt
    /// (Sign Out) instead of a "could not connect / Retry" banner.
    /// ``authEnvironmentMismatch`` is deliberately NOT one: re-authenticating
    /// cannot move the account to another Stack project — the remedy is a
    /// build-level change (rebuild with `--prod-auth`), not signing out.
    public var isAuthorizationFailure: Bool {
        switch self {
        case .accountMismatch, .emailMismatch, .authFailed, .ticketExpired:
            return true
        default:
            return false
        }
    }

    /// The localized headline shown in the pairing error section.
    public var message: String {
        switch self {
        case .offline:
            return L10n.string(
                "mobile.pairing.fail.offline",
                defaultValue: "This device looks offline. Connect to Wi-Fi or cellular, then try again."
            )
        case let .hostUnreachable(host, port):
            return Self.hostPortMessage(
                key: "mobile.pairing.hostUnreachableFormat",
                defaultValue: "Can't reach %@:%d. Make sure your Mac is awake and on the same Tailscale network as this device.",
                fallbackKey: "mobile.pairing.runtimeUnavailable",
                fallbackDefaultValue: "Could not connect to your computer.",
                host: host,
                port: port
            )
        case let .listenerNotRunning(host, port):
            _ = (host, port)
            return L10n.string(
                "mobile.pairing.appNotRunning",
                defaultValue: "Your Mac is reachable, but cmux isn't running there (or mobile pairing is off). Open cmux on the Mac, then try again."
            )
        case .localNetworkBlocked:
            return L10n.string(
                "mobile.pairing.localNetworkPermission",
                defaultValue: "iOS blocked the connection. Allow cmux to use the Local Network in iOS Settings, then try again."
            )
        case let .dnsFailed(host, _):
            if let host {
                return String(
                    format: L10n.string(
                        "mobile.pairing.dnsFailedFormat",
                        defaultValue: "Couldn't resolve %@. Check that Tailscale is connected on both devices."
                    ),
                    host
                )
            }
            return L10n.string(
                "mobile.pairing.runtimeUnavailable",
                defaultValue: "Could not connect to your computer."
            )
        case let .handshakeTimedOut(host, port):
            return Self.hostPortMessage(
                key: "mobile.pairing.connectTimedOutFormat",
                defaultValue: "No response from %@:%d. Your Mac may be asleep or off Tailscale. Make sure it's awake and on the same Tailscale network.",
                fallbackKey: "mobile.pairing.requestTimedOut",
                fallbackDefaultValue: "The computer did not respond. Check the host and port, then try again.",
                host: host,
                port: port
            )
        case let .connectionDropped(host, port):
            return Self.hostPortMessage(
                key: "mobile.pairing.connectionDroppedFormat",
                defaultValue: "Connected to %@:%d, but the host closed the connection. Check that the host app is still running.",
                fallbackKey: "mobile.pairing.runtimeUnavailable",
                fallbackDefaultValue: "Could not connect to your computer.",
                host: host,
                port: port
            )
        case .accountMismatch:
            return L10n.string(
                "mobile.pairing.accountMismatch",
                defaultValue: "This Mac is signed in to a different cmux account. Sign out and sign back in with the account that owns this Mac."
            )
        case let .emailMismatch(expected, actual):
            let format = if let actual, !actual.isEmpty {
                L10n.string(
                    "mobile.pairing.emailMismatchFormat",
                    defaultValue: "This QR is for %@, but this iPhone is signed in as %@. Sign in with the same email as the Mac, then scan again."
                )
            } else {
                L10n.string(
                    "mobile.pairing.emailMissingFormat",
                    defaultValue: "This QR is for %@. Sign in with the same email as the Mac, then scan again."
                )
            }
            if let actual, !actual.isEmpty {
                return String(format: format, expected, actual)
            }
            return String(format: format, expected)
        case .authFailed:
            return L10n.string(
                "mobile.pairing.authorizationFailed",
                defaultValue: "Couldn't verify your account with this Mac. Make sure both devices are signed in with the same email, then try again."
            )
        case .authEnvironmentMismatch:
            return L10n.string(
                "mobile.pairing.authEnvironmentMismatch",
                defaultValue: "This dev build is signed in to cmux's development auth environment, so its account can never match a Mac running the release app — even with the same email."
            )
        case .ticketExpired:
            return L10n.string(
                "mobile.pairing.attachTicketExpired",
                defaultValue: "This pairing link expired. Pair again with a fresh QR/link from that computer."
            )
        case .invalidCode:
            return L10n.string(
                "mobile.pairing.invalidCode",
                defaultValue: "This isn't a cmux pairing QR. Scan the code shown in the Pair iPhone window on your Mac."
            )
        case .unrecognizedVersion:
            return L10n.string(
                "mobile.pairing.unrecognizedVersion",
                defaultValue: "This QR needs a newer version of cmux. Update the app and try again."
            )
        case .loopbackRejected:
            return L10n.string(
                "mobile.pairing.loopbackRejected",
                defaultValue: "This code points at the Mac itself (localhost), so your iPhone can't use it. Set up Tailscale on the Mac, then scan a fresh code."
            )
        case .unsupportedRoute:
            return L10n.string(
                "mobile.pairing.secureRouteRequired",
                defaultValue: "This pairing route is not allowed. Enter a host and port, or pair with a QR/link from that computer."
            )
        case .noSupportedRoute:
            return L10n.string(
                "mobile.pairing.unsupportedRoute",
                defaultValue: "This pairing code is not supported."
            )
        case .cancelled:
            return ""
        case let .unknown(host, port):
            return Self.hostPortMessage(
                key: "mobile.pairing.connectionFailedFormat",
                defaultValue: "Could not reach %@:%d. Check that the host is reachable over Tailscale or LAN and that the port is correct.",
                fallbackKey: "mobile.pairing.runtimeUnavailable",
                fallbackDefaultValue: "Could not connect to your computer.",
                host: host,
                port: port
            )
        }
    }

    /// A second, shorter line of actionable next steps shown beneath the
    /// headline. `nil` for categories whose headline is already the full
    /// instruction (auth, invalid code, cancelled).
    public var guidance: String? {
        switch self {
        case .offline:
            return nil
        case .hostUnreachable, .dnsFailed, .handshakeTimedOut:
            return L10n.string(
                "mobile.pairing.guidance.reachability",
                defaultValue: "Check that this phone and your Mac are on the same Wi-Fi or both running Tailscale, that the Mac is awake, and that cmux is open on it."
            )
        case .listenerNotRunning, .connectionDropped:
            return L10n.string(
                "mobile.pairing.guidance.openMacApp",
                defaultValue: "Open cmux on your Mac, then scan the QR or link from it again."
            )
        case .localNetworkBlocked:
            return L10n.string(
                "mobile.pairing.guidance.localNetwork",
                defaultValue: "Settings > cmux > Local Network, then try again."
            )
        case .accountMismatch, .emailMismatch, .authFailed:
            return L10n.string(
                "mobile.pairing.guidance.sameAccount",
                defaultValue: "Both devices must be signed in to the same cmux account."
            )
        case .authEnvironmentMismatch:
            return L10n.string(
                "mobile.pairing.guidance.authEnvironment",
                defaultValue: "Rebuild this app with production auth (ios/scripts/reload.sh --prod-auth), or pair with a dev-channel Mac signed in to the same account."
            )
        case .ticketExpired, .unsupportedRoute, .noSupportedRoute:
            return L10n.string(
                "mobile.pairing.guidance.rescanFresh",
                defaultValue: "Open the pairing window on your Mac and scan a fresh QR or link."
            )
        case .unrecognizedVersion:
            return L10n.string(
                "mobile.pairing.guidance.updateApp",
                defaultValue: "Update cmux from the App Store (or TestFlight), then scan again."
            )
        case .invalidCode, .loopbackRejected, .cancelled, .unknown:
            return nil
        }
    }

    /// The single mapping from a thrown error (and the route it failed on) to a
    /// category. Order matters: the rich transport failure kinds are checked
    /// first, then the RPC-level errors, then cancellation, then a generic
    /// fallback that still produces an actionable message.
    public static func classify(error: any Error, route: CmxAttachRoute?) -> MobilePairingFailureCategory {
        let hostPort = route.flatMap(hostPort(for:))
        let host = hostPort?.host
        let port = hostPort?.port

        if let networkError = error as? CmxNetworkByteTransportError {
            switch networkError {
            case .connectionTimedOut:
                return .handshakeTimedOut(host: host, port: port)
            case let .connectionFailed(_, kind):
                switch kind {
                case .connectionRefused:
                    return .listenerNotRunning(host: host, port: port)
                case .permissionDenied:
                    return .localNetworkBlocked
                case .hostUnreachable:
                    return .hostUnreachable(host: host, port: port)
                case .dnsFailed:
                    return .dnsFailed(host: host, port: port)
                case .timedOut:
                    return .handshakeTimedOut(host: host, port: port)
                case .secureChannelFailed, .generic:
                    return .unknown(host: host, port: port)
                }
            case .notConnected, .alreadyClosed:
                return .unknown(host: host, port: port)
            case .receiveFailed, .sendFailed:
                return .connectionDropped(host: host, port: port)
            case .emptyHost, .invalidPort, .invalidMaximumReceiveLength,
                 .unsupportedRouteKind, .unsupportedEndpoint,
                 .receiveAlreadyInProgress, .sendAlreadyInProgress:
                return .unknown(host: host, port: port)
            }
        }

        if let connectionError = error as? MobileShellConnectionError {
            switch connectionError {
            case .requestTimedOut:
                return .handshakeTimedOut(host: host, port: port)
            case .insecureManualRoute:
                return .unsupportedRoute
            case .attachTicketExpired:
                return .ticketExpired
            case .authorizationFailed:
                return .authFailed
            case .accountMismatch:
                return .accountMismatch
            case .connectionClosed:
                return .connectionDropped(host: host, port: port)
            case .invalidResponse:
                return .unknown(host: host, port: port)
            case let .rpcError(code, message):
                return classifyRPCError(code: code, message: message, host: host, port: port)
            }
        }

        if error is CancellationError {
            return .cancelled
        }
        return .unknown(host: host, port: port)
    }

    /// Maps an RPC error code/message pair to the auth-flavored categories when
    /// the host rejected the request for an authorization reason, falling back
    /// to ``unknown(host:port:)`` so the user still gets an actionable message
    /// for unrecognized codes.
    private static func classifyRPCError(
        code: String?,
        message: String,
        host: String?,
        port: Int?
    ) -> MobilePairingFailureCategory {
        let normalizedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalizedCode {
            if normalizedCode == "account_mismatch" {
                return .accountMismatch
            }
            if ["unauthorized", "forbidden", "invalid_token", "token_expired",
                "expired_token", "auth_required"].contains(normalizedCode) {
                return .authFailed
            }
        }
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedMessage.contains("unauthorized")
            || normalizedMessage.contains("forbidden")
            || normalizedMessage.contains("invalid token")
            || normalizedMessage.contains("expired token")
            || normalizedMessage.contains("token expired") {
            return .authFailed
        }
        return .unknown(host: host, port: port)
    }

    /// The host/port pair a direct route dials, when the route has one (used to
    /// name the address that was tried in failure messages).
    private static func hostPort(for route: CmxAttachRoute) -> (host: String, port: Int)? {
        guard case let .hostPort(host, port) = route.endpoint else {
            return nil
        }
        return (host, port)
    }

    /// Formats a host/port failure message, falling back to a generic localized
    /// message when the failed route has no host/port to name.
    private static func hostPortMessage(
        key: StaticString,
        defaultValue: String.LocalizationValue,
        fallbackKey: StaticString,
        fallbackDefaultValue: String.LocalizationValue,
        host: String?,
        port: Int?
    ) -> String {
        guard let host, let port else {
            return L10n.string(fallbackKey, defaultValue: fallbackDefaultValue)
        }
        return String(format: L10n.string(key, defaultValue: defaultValue), host, port)
    }
}
