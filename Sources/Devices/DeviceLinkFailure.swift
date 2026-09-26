import CMUXMobileCore
import CmuxIrxTransport
import CmuxMobileRPC
import Foundation

/// Why a device link's last dial or live session failed, as the reconnect
/// policy, the row, and the diagnostics need it: one class that decides
/// recovery, one machine-readable code, and one localized sentence.
///
/// The class is the contract. `transient` retries with the bounded backoff;
/// every other kind parks the link until a signal that could change the
/// answer arrives (an explicit Refresh, a route or pairing change, and for a
/// host refusal a new directory revision). Nothing here is timer-driven.
struct DeviceLinkFailure: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        /// A network or transport blip; the next attempt may succeed unchanged.
        case transient
        /// The other Mac accepted the connection at the transport and refused
        /// admission: its directory does not authorize this Mac.
        case hostDenied = "host-denied"
        /// The answering Mac is not the one this row names, or not this account's.
        case identity
        /// No usable route, or the two builds cannot talk to each other.
        case unsupported
        /// The Devices service that issued this Mac's directory does not
        /// implement the rule Mac-to-Mac admission relies on.
        case controlPlaneOutdated = "control-plane-outdated"
    }

    let kind: Kind
    /// A stable identifier for logs and reports (a close code, a selection
    /// error name, an RPC code); never shown to the person.
    let code: String
    /// The sentence the row shows.
    let message: String

    var isRetryable: Bool { kind == .transient }

    /// The directory this Mac holds names no Mac-to-Mac admission rule, so
    /// the host cannot have been told to admit it; no dial can change that.
    static func controlPlaneOutdated() -> DeviceLinkFailure {
        DeviceLinkFailure(
            kind: .controlPlaneOutdated, code: DeviceLinkControlPlaneRules.macPeerInbound,
            message: String(localized: "devices.link.error.controlPlaneOutdated", defaultValue: "The Devices service is out of date. Connections between Macs resume once it updates.")
        )
    }

    /// Maps a dial or session error to its failure class. `hostName` names the
    /// other Mac in refusals that are about that Mac's decision.
    static func classify(_ error: any Error, hostName: String) -> DeviceLinkFailure {
        if let denial = error as? IrxAdmissionDenied {
            return admission(denial.code, hostName: hostName)
        }
        if let error = error as? IrxMacPeerAuthorization.Failure {
            return peerAuthorization(error)
        }
        if let error = error as? DeviceRouteSelector.SelectionError {
            switch error {
            case .noRoutes:
                return DeviceLinkFailure(kind: .unsupported, code: "no-routes", message: String(localized: "devices.link.error.noRoutes", defaultValue: "This Mac has not published a route yet."))
            case .needsAuthorization:
                return DeviceLinkFailure(kind: .unsupported, code: "needs-authorization", message: Self.needsAuthorizationMessage)
            case .noDialableRoute:
                return DeviceLinkFailure(kind: .unsupported, code: "no-dialable-route", message: String(localized: "devices.link.error.noDialableRoute", defaultValue: "This Mac has no supported connection route. Update cmux on both Macs and try again."))
            }
        }
        if let error = error as? DeviceLinkError {
            let message = error.errorDescription ?? String(describing: error)
            switch error {
            case .identityUnproven:
                return DeviceLinkFailure(kind: .identity, code: "identity-unproven", message: message)
            case .identityMismatch:
                return DeviceLinkFailure(kind: .identity, code: "identity-mismatch", message: message)
            case .blocked:
                return DeviceLinkFailure(kind: .unsupported, code: "blocked", message: message)
            case .notConnected:
                return DeviceLinkFailure(kind: .transient, code: "not-connected", message: message)
            case .hostRejected(let code, _):
                return DeviceLinkFailure(kind: .transient, code: "host-rejected:" + (code ?? "unknown"), message: message)
            case .malformedResponse(let method):
                return DeviceLinkFailure(kind: .transient, code: "malformed-response:" + method, message: message)
            }
        }
        if let error = error as? MobileShellConnectionError {
            switch error {
            case .accountMismatch, .authorizationFailed:
                return DeviceLinkFailure(kind: .identity, code: "authorization-failed", message: DeviceLinkError.identityUnproven.localizedDescription)
            case .insecureManualRoute:
                return DeviceLinkFailure(kind: .unsupported, code: "insecure-manual-route", message: Self.needsAuthorizationMessage)
            default:
                break
            }
        }
        return DeviceLinkFailure(kind: .transient, code: "connection-failed", message: Self.connectionFailedMessage)
    }

    /// The host's admission verdict travels in the QUIC close reason. Every
    /// code is mapped here, so a new code cannot fall into the retry loop.
    private static func admission(_ code: IrxCloseCode, hostName: String) -> DeviceLinkFailure {
        switch code {
        case .invalidGrant:
            return DeviceLinkFailure(kind: .hostDenied, code: code.rawValue, message: String(
                format: String(localized: "devices.link.error.hostDenied", defaultValue: "%@ has not authorized this Mac. Update cmux on both Macs, then refresh."),
                hostName
            ))
        case .grantExpired:
            return DeviceLinkFailure(kind: .hostDenied, code: code.rawValue, message: String(
                format: String(localized: "devices.link.error.hostGrantExpired", defaultValue: "%@ no longer holds an authorization for this Mac. Refresh to try again."),
                hostName
            ))
        case .revoked:
            return DeviceLinkFailure(kind: .hostDenied, code: code.rawValue, message: String(
                format: String(localized: "devices.link.error.hostRevoked", defaultValue: "%@ revoked this Mac’s access."),
                hostName
            ))
        case .identityMismatch:
            return DeviceLinkFailure(kind: .identity, code: code.rawValue, message: DeviceLinkError.identityMismatch.localizedDescription)
        case .malformedHello, .protocolMismatch:
            return DeviceLinkFailure(kind: .unsupported, code: code.rawValue, message: DeviceLinkError.malformedResponse("admission").localizedDescription)
        case .admissionTimeout, .superseded, .userRequested, .hostShutdown, .keepaliveTimeout, .explicitRedial:
            return DeviceLinkFailure(kind: .transient, code: code.rawValue, message: Self.connectionFailedMessage)
        }
    }

    /// This Mac's own directory refused the dial before it left the machine.
    private static func peerAuthorization(_ failure: IrxMacPeerAuthorization.Failure) -> DeviceLinkFailure {
        switch failure {
        case .staleDirectory:
            return DeviceLinkFailure(kind: .transient, code: "stale-directory", message: String(localized: "devices.link.error.staleDirectory", defaultValue: "Waiting for the Devices directory to refresh…"))
        case .unavailable:
            return DeviceLinkFailure(kind: .transient, code: "peer-unavailable", message: String(localized: "devices.link.error.peerUnavailable", defaultValue: "This Mac is not accepting connections right now."))
        case .notDiscoverable:
            return DeviceLinkFailure(kind: .hostDenied, code: "peer-not-discoverable", message: String(localized: "devices.link.error.notDiscoverable", defaultValue: "This Mac isn’t discoverable. On that Mac, turn on “Make this Mac discoverable” in Settings › Computers."))
        case .revoked:
            return DeviceLinkFailure(kind: .identity, code: "peer-revoked", message: String(localized: "devices.link.error.peerRevoked", defaultValue: "Access between these Macs was revoked. Sign in again on both Macs to restore it."))
        case .identityMismatch:
            return DeviceLinkFailure(kind: .identity, code: "peer-identity-mismatch", message: DeviceLinkError.identityMismatch.localizedDescription)
        }
    }

    static var needsAuthorizationMessage: String {
        String(localized: "devices.link.error.needsAuthorization", defaultValue: "Pair this Mac in Settings › Mobile › Computers to connect.")
    }

    static var connectionFailedMessage: String {
        String(localized: "devices.link.error.connectionFailed", defaultValue: "Could not connect to this Mac. Check that it is online and try again.")
    }
}
