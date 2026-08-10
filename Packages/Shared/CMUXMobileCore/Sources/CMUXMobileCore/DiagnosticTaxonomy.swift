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
    /// The established transport exceeded its negotiated inactivity window.
    case transportIdleTimedOut = 21
    /// Online admission closed the session because its signed lease expired.
    case admissionLeaseExpired = 22
    /// Online admission closed the session after broker revalidation failed.
    case admissionRevalidationFailed = 23
    /// The local side closed an admitted session because its bounded outbound
    /// event queue overflowed while the transport stopped draining (for
    /// example the peer's network path died mid-write).
    case sendQueueOverflow = 24
    /// The connect-attempt registry refused a dial because the exact route is
    /// held by an in-flight connect attempt. Distinguishes gate refusals from
    /// genuine dial timeouts in exports; a gated attempt never reached the
    /// network.
    case routeGated = 25
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
    /// Every usable transport path disappeared from an admitted session.
    case allPathsClosed = 11
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

/// High-level lifecycle state for one phone-controlled Simulator stream.
///
/// Values intentionally omit panel UUIDs, device names, workspace titles, and
/// frame contents. The associated ``DiagnosticEvent`` carries only a
/// process-local surface handle and bounded counters.
public enum DiagnosticSimulatorStreamLifecycle: Int, Sendable, Codable, CaseIterable {
    case startRequested = 1
    case started = 2
    case locked = 3
    case startFailed = 4
    case stopRequested = 5
    case stopped = 6
    case closed = 7
    case restartRequested = 8
    case pausedForBackground = 9
    case descriptorApplied = 10
    /// The client's staleness watchdog saw a full silent interval (no frame
    /// or keepalive) for an active stream and is re-requesting it.
    case stalled = 11
}

/// Frame-pipeline state for the Simulator video stream.
public enum DiagnosticSimulatorFrameLifecycle: Int, Sendable, Codable, CaseIterable {
    case readerAttached = 1
    case readerMissing = 2
    case copied = 3
    case encodeFailed = 4
    case sent = 5
    case refused = 6
    case cachedSent = 7
    case subscriptionReasserted = 8
    case received = 9
    case staleIgnored = 10
    case decodeFailed = 11
    case imageDecoded = 12
    case imageDecodeFailed = 13
    case unknownPanel = 14
}

/// Input delivery state for phone-originated Simulator actions.
public enum DiagnosticSimulatorInputLifecycle: Int, Sendable, Codable, CaseIterable {
    case queued = 1
    case sent = 2
    case accepted = 3
    case failed = 4
    case rejectedLocked = 5
    case unavailable = 6
    case invalidParameters = 7
    case panelMissing = 8
    case featureDisabled = 9
    case blockedViewOnly = 10
}

/// Phone-originated Simulator input category.
public enum DiagnosticSimulatorInputKind: Int, Sendable, Codable, CaseIterable {
    case pointer = 1
    case text = 2
    case hardwareButton = 3
}

/// Hardware button category for phone-originated Simulator actions.
public enum DiagnosticSimulatorHardwareButtonKind: Int, Sendable, Codable, CaseIterable {
    case unknown = 0
    case home = 1
    case swipeHome = 2
    case appSwitcher = 3
    case lock = 4
    case siri = 5
    case sideButton = 6
    case power = 7
    case volumeUp = 8
    case volumeDown = 9
    case action = 10
    case watchSideButton = 11
}

/// Pointer phase for phone-originated Simulator touch events.
public enum DiagnosticSimulatorPointerPhase: Int, Sendable, Codable, CaseIterable {
    case began = 1
    case moved = 2
    case ended = 3
    case tap = 4
}

/// Privacy-safe ownership state for a Simulator pane's active controller.
public enum DiagnosticSimulatorOwnershipState: Int, Sendable, Codable, CaseIterable {
    case unowned = 0
    case currentConnection = 1
    case otherConnection = 2
    case pendingHandshake = 3
    case unknown = 4
}

/// Coordinate mapping state for a phone gesture before it leaves the device.
public enum DiagnosticSimulatorCoordinateState: Int, Sendable, Codable, CaseIterable {
    case mapped = 1
    case outsideImage = 2
    case viewOnlyBlocked = 3
    case zeroImage = 4
}
