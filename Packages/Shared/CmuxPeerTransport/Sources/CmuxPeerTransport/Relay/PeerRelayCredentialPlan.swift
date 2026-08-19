public import Foundation

/// Failures building a relay credential plan from a policy and a minted token.
public enum PeerRelayCredentialPlanError: Error, Equatable, Sendable {
    /// The minted credentials do not cover exactly the verified policy fleet.
    case fleetMismatch

    /// A credential is malformed, duplicated, over-sized, or already stale.
    case invalidCredential
}

/// Deterministic jitter source for relay credential refresh scheduling.
///
/// Jitter spreads refresh mints across the fleet so every endpoint holding a
/// token from the same mint minute does not hit the broker simultaneously.
public struct PeerRelayRefreshJitter: Sendable {
    /// The maximum seconds a refresh is advanced before `refreshAfter`.
    public static let window: TimeInterval = 30

    private let unitInterval: @Sendable () -> Double

    /// Creates a jitter source from a unit-interval sampler.
    ///
    /// - Parameter unitInterval: Returns a value in `[0, 1]`; injected for
    ///   deterministic tests.
    public init(unitInterval: @escaping @Sendable () -> Double) {
        self.unitInterval = unitInterval
    }

    /// The production jitter source.
    public static func system() -> PeerRelayRefreshJitter {
        PeerRelayRefreshJitter { Double.random(in: 0 ... 1) }
    }

    /// The jittered deadline: uniform in
    /// `[refreshAfter - min(window, refreshAfter - now), refreshAfter]`,
    /// clamped to `[now, refreshAfter]`.
    func deadline(now: Date, refreshAfter: Date) -> Date {
        let window = min(Self.window, max(0, refreshAfter.timeIntervalSince(now)))
        let sample = min(1, max(0, unitInterval()))
        let candidate = refreshAfter.addingTimeInterval(-sample * window)
        return min(refreshAfter, max(now, candidate))
    }
}

/// When the endpoint should mint a replacement relay credential.
public struct PeerRelayRefreshSchedule: Equatable, Sendable {
    /// The jittered time to mint a replacement; always at or before
    /// ``refreshAfter`` and therefore strictly before ``expiresAt``.
    public let refreshDeadline: Date

    /// The earliest credential `refreshAfter` across the applied fleet.
    public let refreshAfter: Date

    /// The earliest hard credential expiry across the applied fleet.
    public let expiresAt: Date

    init(refreshDeadline: Date, refreshAfter: Date, expiresAt: Date) {
        self.refreshDeadline = refreshDeadline
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
    }
}

/// The relay configuration set to apply for one verified policy and one
/// minted endpoint-bound credential, plus its refresh schedule.
///
/// The plan is pure data: the endpoint executor applies ``configs`` and the
/// credential coordinator sleeps until ``schedule``'s deadline.
public struct PeerRelayCredentialPlan: Equatable, Sendable {
    /// Validated relay configurations, ordered by the policy catalog.
    public let configs: [PeerRelayConfig]

    /// The jittered refresh schedule for the applied credential set.
    public let schedule: PeerRelayRefreshSchedule

    /// Builds the plan for one verified policy and one minted credential set.
    ///
    /// The minted fleet must cover exactly the policy fleet (same URL set,
    /// one credential per relay); anything else is a fleet mismatch so a
    /// partial or substituted mint can never configure relays the signed
    /// policy did not name.
    ///
    /// - Parameters:
    ///   - policy: A root-verified relay policy.
    ///   - minted: The broker-minted endpoint-bound credential response.
    ///   - now: The validation time.
    ///   - jitter: Refresh jitter source, injected for deterministic tests.
    /// - Throws: ``PeerRelayCredentialPlanError`` when the mint does not
    ///   match the policy or a credential fails validation.
    public init(
        policy: PeerRelayPolicy,
        minted: PeerRelayTokenResponse,
        now: Date,
        jitter: PeerRelayRefreshJitter = .system()
    ) throws {
        let policyURLs = Set(policy.relays.map(\.url))
        guard minted.credentials.count == policy.relays.count,
              Set(minted.credentials.map(\.relayURL)) == policyURLs else {
            throw PeerRelayCredentialPlanError.fleetMismatch
        }
        let unordered = try minted.relayConfigs(now: now)
        let byURL = Dictionary(
            uniqueKeysWithValues: unordered.map { ($0.url, $0) }
        )
        let ordered = policy.relays.compactMap { byURL[$0.url] }
        guard ordered.count == policy.relays.count,
              let earliestRefresh = ordered.map(\.refreshAfter).min(),
              let earliestExpiry = ordered.map(\.expiresAt).min() else {
            throw PeerRelayCredentialPlanError.fleetMismatch
        }
        configs = ordered
        schedule = PeerRelayRefreshSchedule(
            refreshDeadline: jitter.deadline(now: now, refreshAfter: earliestRefresh),
            refreshAfter: earliestRefresh,
            expiresAt: earliestExpiry
        )
    }
}
