import Foundation

/// A locally verified pair grant, produced by the crypto layer before the
/// controller consults the broker.
public struct PeerVerifiedGrant: Sendable, Equatable {
    public let grantID: String
    public let initiatorDeviceID: String
    public let acceptorDeviceID: String
    public let initiatorEndpointID: String
    public let expiresAt: Date

    public init(
        grantID: String,
        initiatorDeviceID: String,
        acceptorDeviceID: String,
        initiatorEndpointID: String,
        expiresAt: Date
    ) {
        self.grantID = grantID
        self.initiatorDeviceID = initiatorDeviceID
        self.acceptorDeviceID = acceptorDeviceID
        self.initiatorEndpointID = initiatorEndpointID
        self.expiresAt = expiresAt
    }
}

/// Broker's answer for one grant, or the reason it could not answer.
public enum PeerBrokerAdmissionVerdict: Sendable, Equatable {
    /// Exactly one matching binding pair, pairing enabled.
    case admitted
    /// Positive online denial: revoked, ambiguous, disabled. Sticky.
    case denied(String)
    /// The broker was unreachable. The ONLY verdict that permits a locally
    /// valid signed grant to continue offline.
    case unreachable
}

/// Single-phase admission: verify the grant locally, revalidate against the
/// broker, and keep revalidating on a bounded cadence while the session
/// lives. Ports the accepted authorization semantics from
/// `docs/iroh-app-transport-architecture.md` without the two-phase barrier:
/// - only broker connectivity failure lets a locally valid grant continue;
/// - a valid online denial is STICKY for the process runtime — later
///   connectivity failure cannot restore offline access;
/// - revalidation runs at most every `revalidationInterval` (30s), measured
///   from snapshot fetch time, and a confirmed revoke closes the session;
/// - the session closes at grant expiry even when idle.
public actor PeerAdmissionController {
    public struct Configuration: Sendable {
        public let revalidationInterval: Duration
        public init(revalidationInterval: Duration = .seconds(30)) {
            self.revalidationInterval = revalidationInterval
        }
    }

    public enum Decision: Sendable, Equatable {
        case admitted(PeerVerifiedGrant)
        case denied(reason: String)
    }

    private let configuration: Configuration
    private let verifyGrant: @Sendable (String) async throws -> PeerVerifiedGrant
    private let brokerVerdict: @Sendable (PeerVerifiedGrant) async -> PeerBrokerAdmissionVerdict
    private let now: @Sendable () -> Date

    /// Grant IDs a valid online snapshot has denied. Sticky for the runtime.
    private var stickyDenials: Set<String> = []
    /// Most recent successful broker verdict per grant, shared across
    /// concurrent admissions for the revalidation interval.
    private var cachedVerdicts: [String: (verdict: PeerBrokerAdmissionVerdict, fetchedAt: Date)] = [:]

    public init(
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        verifyGrant: @escaping @Sendable (String) async throws -> PeerVerifiedGrant,
        brokerVerdict: @escaping @Sendable (PeerVerifiedGrant) async -> PeerBrokerAdmissionVerdict
    ) {
        self.configuration = configuration
        self.now = now
        self.verifyGrant = verifyGrant
        self.brokerVerdict = brokerVerdict
    }

    /// Admit or deny one inbound control stream credential.
    ///
    /// - Parameter expectedInitiatorEndpointID: the TLS-proven remote
    ///   EndpointID of the connection carrying the credential. The grant is
    ///   admitted only when it is bound to that exact endpoint.
    public func admit(
        credential: String,
        expectedInitiatorEndpointID: String
    ) async -> Decision {
        let grant: PeerVerifiedGrant
        do {
            grant = try await verifyGrant(credential)
        } catch {
            return .denied(reason: "invalid-grant")
        }
        guard grant.initiatorEndpointID.lowercased() == expectedInitiatorEndpointID.lowercased() else {
            return .denied(reason: "endpoint-mismatch")
        }
        guard grant.expiresAt > now() else {
            return .denied(reason: "expired-grant")
        }
        guard !stickyDenials.contains(grant.grantID) else {
            return .denied(reason: "denied-sticky")
        }

        switch await freshVerdict(for: grant) {
        case .admitted:
            return .admitted(grant)
        case .denied(let reason):
            return .denied(reason: reason)
        case .unreachable:
            // Locally valid signed grant continues offline; this is the
            // deliberate residual disconnected-revocation window bounded by
            // grant expiry.
            return .admitted(grant)
        }
    }

    /// Runs until the session must close, returning the close reason. The
    /// caller races this against the session's own lifetime.
    public func revalidationMonitor(
        grant: PeerVerifiedGrant,
        clock: ContinuousClock = ContinuousClock()
    ) async -> PeerSessionCloseReason {
        while !Task.isCancelled {
            let remaining = now().distance(to: grant.expiresAt)
            guard remaining > 0 else {
                return .local("grant-expired")
            }
            let sleepFor = min(
                configuration.revalidationInterval,
                .seconds(Int64(remaining.rounded(.up)))
            )
            do {
                try await clock.sleep(for: sleepFor)
            } catch {
                return .local("monitor-cancelled")
            }
            if stickyDenials.contains(grant.grantID) {
                return .revoked
            }
            switch await freshVerdict(for: grant) {
            case .admitted:
                continue
            case .denied:
                return .revoked
            case .unreachable:
                // Connectivity failure preserves the session and retries.
                continue
            }
        }
        return .local("monitor-cancelled")
    }

    private func freshVerdict(for grant: PeerVerifiedGrant) async -> PeerBrokerAdmissionVerdict {
        if let cached = cachedVerdicts[grant.grantID],
            now().timeIntervalSince(cached.fetchedAt) < configuration.revalidationInterval.timeInterval
        {
            return cached.verdict
        }
        let verdict = await brokerVerdict(grant)
        switch verdict {
        case .admitted, .denied:
            // Only real online answers are cacheable or sticky.
            cachedVerdicts[grant.grantID] = (verdict, now())
            if case .denied = verdict {
                stickyDenials.insert(grant.grantID)
            }
        case .unreachable:
            break
        }
        return verdict
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}
