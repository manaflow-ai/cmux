import Foundation

/// The app transport involved in a diagnostic event.
///
/// Raw values are stable export vocabulary. Append new cases; never renumber
/// an existing case.
public enum DiagnosticTransportKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case iroh = 1
    case tailscale = 2
    case websocket = 3
    case debugLoopback = 4

    /// Maps a pairing-route transport without preserving its address or other
    /// route metadata.
    public init(_ kind: CmxAttachTransportKind) {
        switch kind {
        case .iroh:
            self = .iroh
        case .tailscale:
            self = .tailscale
        case .websocket:
            self = .websocket
        case .debugLoopback:
            self = .debugLoopback
        }
    }
}

public extension CmxAttachTransportKind {
    /// A privacy-safe integer category suitable for diagnostic payloads.
    var diagnosticTransportKind: DiagnosticTransportKind {
        DiagnosticTransportKind(self)
    }
}

/// A stable, privacy-safe classification for connection failures.
///
/// This vocabulary intentionally excludes raw error text, addresses, endpoint
/// IDs, account data, and provider responses. Unknown errors remain
/// ``unknown`` instead of being serialized as strings.
public enum DiagnosticFailureKind: Int, Sendable, Codable, CaseIterable {
    case none = 0
    case offline = 1
    case timedOut = 2
    case connectionRefused = 3
    case hostUnreachable = 4
    case permissionDenied = 5
    case dnsFailed = 6
    case secureChannelFailed = 7
    case unsupportedRoute = 8
    case noRoute = 9
    case credentialUnavailable = 10
    case policyUnavailable = 11
    case endpointUnavailable = 12
    case identityMismatch = 13
    case admissionDenied = 14
    case authorizationFailed = 15
    case accountMismatch = 16
    case protocolViolation = 17
    case connectionClosed = 18
    case superseded = 19
    case cancelled = 20
    case unknown = 255

    /// Reduces a typed or system error to the bounded diagnostic vocabulary.
    ///
    /// Domain-specific errors should conform to ``DiagnosticFailureProviding``
    /// so their mapping stays close to the source. The fallback recognizes only
    /// stable Foundation/POSIX codes and never retains the error's description.
    public static func classify(_ error: any Error) -> DiagnosticFailureKind {
        if let providing = error as? any DiagnosticFailureProviding {
            return providing.diagnosticFailureKind
        }
        if error is CancellationError {
            return .cancelled
        }

        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return .offline
            case NSURLErrorTimedOut:
                return .timedOut
            case NSURLErrorCannotConnectToHost:
                return .connectionRefused
            case NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return .dnsFailed
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return .secureChannelFailed
            case NSURLErrorUserAuthenticationRequired:
                return .authorizationFailed
            case NSURLErrorNetworkConnectionLost:
                return .connectionClosed
            case NSURLErrorCancelled:
                return .cancelled
            default:
                return .unknown
            }
        }

        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(POSIXErrorCode.ECONNREFUSED.rawValue):
                return .connectionRefused
            case Int(POSIXErrorCode.EHOSTUNREACH.rawValue),
                 Int(POSIXErrorCode.ENETUNREACH.rawValue):
                return .hostUnreachable
            case Int(POSIXErrorCode.ETIMEDOUT.rawValue):
                return .timedOut
            case Int(POSIXErrorCode.EACCES.rawValue),
                 Int(POSIXErrorCode.EPERM.rawValue):
                return .permissionDenied
            case Int(POSIXErrorCode.ECONNRESET.rawValue),
                 Int(POSIXErrorCode.EPIPE.rawValue),
                 Int(POSIXErrorCode.ENOTCONN.rawValue):
                return .connectionClosed
            case Int(POSIXErrorCode.ECANCELED.rawValue):
                return .cancelled
            default:
                return .unknown
            }
        }

        return .unknown
    }
}

/// Adopted by transport and policy errors that can provide a safe failure
/// category without exporting their raw associated values or description.
public protocol DiagnosticFailureProviding: Error, Sendable {
    var diagnosticFailureKind: DiagnosticFailureKind { get }
}

/// The network path selected underneath an app transport.
public enum DiagnosticPathKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case direct = 1
    case relay = 2
    case privateNetwork = 3
    case loopback = 4

    /// Redacts a live Iroh path to its connection class. Managed and custom
    /// relay metadata intentionally collapse to the same ``relay`` value.
    public init(_ path: CmxIrohSelectedTransportPath) {
        switch path {
        case .unavailable:
            self = .unknown
        case .direct:
            self = .direct
        case .privateNetwork:
            self = .privateNetwork
        case .managedRelay, .customRelay:
            self = .relay
        }
    }
}

/// Why an admitted transport session entered or left its local pool.
///
/// Raw values are stable export vocabulary. The cases identify only local
/// lifecycle ownership, never a peer, endpoint, address, account, or raw error.
public enum DiagnosticSessionLifecycleKind: Int, Sendable, Codable, CaseIterable {
    /// A newly authenticated session entered the pool.
    case established = 1
    /// The RPC owner intentionally relinquished its control stream.
    case controlOwnerReleased = 2
    /// The RPC control reader failed and relinquished ownership.
    case controlReadFailed = 3
    /// The RPC control writer failed and relinquished ownership.
    case controlWriteFailed = 4
    /// The transport reported that its peer connection closed.
    case remoteClosed = 5
    /// A caller found a cached session already closed before its watcher ran.
    case closedSessionEvicted = 6
    /// An application-lane operation found the shared connection closed.
    case applicationLaneFailed = 7
    /// The account-scoped runtime stopped.
    case runtimeDeactivated = 8
    /// The runtime generation changed and replaced its prior sessions.
    case runtimeReconfigured = 9
    /// A caller explicitly invalidated one exact peer session.
    case explicitlyInvalidated = 10
}

/// Which component produced a diagnostic report.
public enum DiagnosticRuntimeRole: Int, Sendable, Codable, CaseIterable {
    case unspecified = 0
    case mobileClient = 1
    case macHost = 2
    case broker = 3
    case relay = 4

    /// Source-level spelling used by the current Apple mobile composition.
    public static let iosClient = DiagnosticRuntimeRole.mobileClient
}
