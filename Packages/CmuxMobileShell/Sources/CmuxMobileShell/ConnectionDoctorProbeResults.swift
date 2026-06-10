public import CMUXMobileCore
public import CmuxMobileTransport
import Foundation

/// Everything the connection doctor's live probes observed, as one injectable
/// value.
///
/// ``ConnectionDoctor`` fills this from concurrent environment probes;
/// ``ConnectionDoctorReport/make(results:)`` is a pure function of it. Tests
/// construct it directly to drive every misconfiguration through the
/// probe-to-verdict mapping without a network.
public struct ConnectionDoctorProbeResults: Equatable, Sendable {
    /// How a single TCP dial of one saved route resolved, classified from the
    /// transport's ``CmxConnectFailureKind`` so each outcome maps to a distinct
    /// misconfiguration (refused = app/listener off, unreachable = wrong/no
    /// tailnet, timeout = Mac asleep, permission = Local Network denied).
    public enum DialOutcome: Equatable, Sendable {
        /// The TCP connection became ready: something is listening there.
        case accepted
        /// The host answered but nothing accepted the port (app not running,
        /// or mobile connections are off).
        case refused
        /// No route to the host (Mac off Tailscale, or a different tailnet).
        case unreachable
        /// The dial timed out (Mac asleep, or silently dropping packets).
        case timedOut
        /// DNS could not resolve the host (MagicDNS down on a side).
        case dnsFailed
        /// iOS blocked the dial on Local Network privacy grounds.
        case permissionDenied
        /// Anything else (generic/secure-channel failures).
        case failed
    }

    /// One saved route plus how dialing it resolved.
    public struct RouteDial: Equatable, Sendable {
        public let route: CmxAttachRoute
        public let outcome: DialOutcome

        /// Creates a dialed-route observation.
        /// - Parameters:
        ///   - route: The route that was dialed.
        ///   - outcome: How the dial resolved.
        public init(route: CmxAttachRoute, outcome: DialOutcome) {
            self.route = route
            self.outcome = outcome
        }
    }

    /// How the device-registry cross-check of the saved routes resolved.
    public enum RegistryCrossCheck: Equatable, Sendable {
        /// Not attempted: no registry client, signed out, or no paired Mac.
        case notAttempted
        /// The registry call failed or returned nothing usable.
        case unavailable
        /// The registry advertises the same routes this device has saved.
        case matchesStored
        /// The registry advertises different routes: the saved address is stale.
        case differsFromStored
    }

    /// The composite-side state captured at probe time: the candidate routes,
    /// the paired Mac, the account, and the last classified pairing failure
    /// (the evidence for the auth/ticket checks, which only a real handshake
    /// can exercise).
    public struct ConnectionSnapshot: Equatable, Sendable {
        /// The routes the next connect would dial (active ticket's routes, or
        /// the stored active Mac's routes).
        public var routes: [CmxAttachRoute]
        /// The paired Mac the routes belong to, for the registry cross-check.
        public var macDeviceID: String?
        /// Whether this device currently has a signed-in session.
        public var isSignedIn: Bool
        /// The signed-in account's email, for the account row's detail line.
        public var accountEmail: String?
        /// The last classified pairing failure, if an attempt failed since the
        /// last successful connect.
        public var lastPairingFailure: MobilePairingFailureCategory?
        /// Whether a live, unexpired attach ticket is currently held.
        public var hasActiveUnexpiredTicket: Bool

        /// Creates a snapshot of the connection-relevant shell state.
        /// - Parameters:
        ///   - routes: The candidate routes the next connect would dial.
        ///   - macDeviceID: The paired Mac the routes belong to.
        ///   - isSignedIn: Whether a signed-in session exists.
        ///   - accountEmail: The signed-in account's email, if known.
        ///   - lastPairingFailure: The last classified pairing failure.
        ///   - hasActiveUnexpiredTicket: Whether a live attach ticket is held.
        public init(
            routes: [CmxAttachRoute] = [],
            macDeviceID: String? = nil,
            isSignedIn: Bool = false,
            accountEmail: String? = nil,
            lastPairingFailure: MobilePairingFailureCategory? = nil,
            hasActiveUnexpiredTicket: Bool = false
        ) {
            self.routes = routes
            self.macDeviceID = macDeviceID
            self.isSignedIn = isSignedIn
            self.accountEmail = accountEmail
            self.lastPairingFailure = lastPairingFailure
            self.hasActiveUnexpiredTicket = hasActiveUnexpiredTicket
        }
    }

    /// Whether the system reports a satisfied network path; `nil` when the
    /// reachability probe could not answer.
    public var isOnline: Bool?
    /// The phone-side tailnet status; `nil` when no detector was wired.
    public var tailscale: TailscaleStatus?
    /// The shell-state snapshot the probes ran against.
    public var snapshot: ConnectionSnapshot
    /// The dial outcome for each host/port candidate route.
    public var dials: [RouteDial]
    /// The registry cross-check of the saved routes.
    public var registry: RegistryCrossCheck

    /// Creates a full probe-results value.
    /// - Parameters:
    ///   - isOnline: The reachability observation, or `nil` when unavailable.
    ///   - tailscale: The phone-side tailnet status, or `nil` when unprobed.
    ///   - snapshot: The shell-state snapshot.
    ///   - dials: Dial outcomes for the snapshot's host/port routes.
    ///   - registry: The registry cross-check outcome.
    public init(
        isOnline: Bool? = nil,
        tailscale: TailscaleStatus? = nil,
        snapshot: ConnectionSnapshot = ConnectionSnapshot(),
        dials: [RouteDial] = [],
        registry: RegistryCrossCheck = .notAttempted
    ) {
        self.isOnline = isOnline
        self.tailscale = tailscale
        self.snapshot = snapshot
        self.dials = dials
        self.registry = registry
    }
}
