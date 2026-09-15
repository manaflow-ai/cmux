import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Registers this Mac (and its running cmux app instance's attach routes) in the
/// team-scoped device registry (`POST /api/devices`), so a phone can look up the
/// Mac's current routes on reload and auto-pair instead of re-scanning a QR.
///
/// Event-driven: it observes ``MobileHostService/statusUpdates()`` and registers
/// whenever the advertised route set changes (e.g. the Mac moved networks or
/// rebound to a different port), which is exactly the freshness the phone needs.
/// Gating falls out of the routes: ``MobileHostService`` advertises no routes
/// until the user has enabled mobile pairing, so an empty route set is never
/// registered. There is no separate opt-in flag — the registry is core to the
/// pairing the user already turned on, not a distinct privacy surface.
///
/// Best-effort and non-blocking, mirroring ``PhonePushClient``: a registry
/// outage never disturbs the Mac, and pairing still works through the phone's
/// locally stored routes.
@MainActor
final class DeviceRegistryClient {
    static let shared = DeviceRegistryClient()

    private let session = CmxCredentialedHTTPSession()
    private let retryAfterGate = CmxRetryAfterGate()
    private var auth: AuthCoordinator?
    private var observeTask: Task<Void, Never>?
    /// The scope (team + tag + routes) most recently registered, used to skip
    /// redundant POSTs. Keyed on the full scope rather than routes alone so an
    /// account/team switch with unchanged routes still re-registers in the newly
    /// selected team instead of being deduped away.
    private var lastRegistration: Registration?
    private var latestRoutes: [CmxAttachRoute] = []
    private var observedIdentity: AuthenticatedSessionIdentity?
    private var observedTeamID: String?
    private var publicationTask: Task<Void, Never>?
    private var pendingSignOut: Registration?
    private var activePublication: Registration?
    private var signingOut = false
    private var observedSignedOut = false
    private var lastLeaseRenewal: ContinuousClock.Instant?
    private var leaseTask: Task<Void, Never>?

    /// The identity of a registration POST, for deduplication.
    struct Registration: Equatable {
        var teamID: String?
        var tag: String
        var routes: [CmxAttachRoute]
        var accountID: String? = nil
        var generation: UInt64? = nil
    }

    private init() {}

    /// Inject the auth dependency and begin observing host-route changes. Call
    /// once at the composition root (after `auth` is constructed).
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        startObserving()
        observeAccount()
    }

    /// Whether a registration with `current` scope differs from what was last
    /// registered, and therefore should be POSTed.
    ///
    /// Pure so it is unit-testable without any network or host service.
    ///
    /// Fires (returns `true`) when the team, tag, or routes differ from the last
    /// registration. The team is part of the key so an account/team switch with
    /// unchanged routes still registers in the new team. The routes-empty
    /// transition (the user turned mobile pairing off) also fires once, so the
    /// registry stops advertising stale routes; the phone already skips
    /// empty-route instances. An unchanged scope (a connection-only
    /// `statusUpdates()` tick) and the never-registered empty start (`nil`
    /// previous with empty routes) are both no-ops, so the off-state is published
    /// exactly once rather than on every empty tick.
    nonisolated static func shouldReRegister(
        previous: Registration?,
        current: Registration
    ) -> Bool {
        // Treat "never registered" as an empty-routes baseline in the same scope
        // so an initial empty set (pairing off at launch) is a no-op, but a later
        // clear, or any team/tag change, still fires.
        let baseline = previous ?? Registration(
            teamID: current.teamID, tag: current.tag, routes: [],
            accountID: current.accountID, generation: current.generation
        )
        return baseline != current
    }

    private func startObserving() {
        observeTask?.cancel()
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                self?.latestRoutes = status.routes
                self?.updateLeaseRenewal()
                self?.enqueuePublication()
            }
        }
    }

    private func observeAccount() {
        guard let auth else { return }
        let scope = withObservationTracking {
            (auth.authenticatedSessionIdentity, auth.resolvedTeamID)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeAccount() }
        }
        guard scope.0 != observedIdentity || scope.1 != observedTeamID else { return }
        observedIdentity = scope.0
        observedTeamID = scope.1
        updateLeaseRenewal()
        if scope.0 == nil {
            if signingOut { observedSignedOut = true }
            return
        }
        if signingOut && !observedSignedOut { return }
        signingOut = false
        updateLeaseRenewal()
        enqueuePublication()
    }

    private func enqueuePublication(renewLease: Bool = false) {
        let previous = publicationTask
        publicationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.registerCurrentState(renewLease: renewLease)
        }
    }

    /// Renews the server's discovery lease independently of presence-worker backpressure.
    func maintainAvailabilityLease() {
        guard !signingOut, !latestRoutes.isEmpty,
              MobileRemoteControlPolicy.allowsIncomingAccess(),
              Self.leaseRenewalDue(lastSuccess: lastLeaseRenewal, now: .now) else { return }
        enqueuePublication(renewLease: true)
    }

    private func updateLeaseRenewal() {
        let shouldRun = !signingOut && auth?.authenticatedSessionIdentity != nil
            && !latestRoutes.isEmpty && MobileRemoteControlPolicy.allowsIncomingAccess()
        if !shouldRun {
            leaseTask?.cancel()
            leaseTask = nil
            return
        }
        guard leaseTask == nil else { return }
        leaseTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                // This delay is the lease renewal cadence, not UI synchronization.
                do { try await clock.sleep(for: .seconds(60)) } catch { return }
                self?.maintainAvailabilityLease()
            }
        }
    }

    nonisolated static func leaseRenewalDue(lastSuccess: ContinuousClock.Instant?, now: ContinuousClock.Instant) -> Bool {
        guard let lastSuccess else { return true }
        return lastSuccess.duration(to: now) >= .seconds(60)
    }

    /// Capture the old registration before the auth coordinator clears local credentials.
    func beginSignOut() {
        signingOut = true
        observedSignedOut = false
        pendingSignOut = activePublication ?? lastRegistration
        updateLeaseRenewal()
    }

    /// Runs in the auth coordinator's bounded teardown hook with its captured old credentials.
    func withdrawForSignOut(accessToken: String?, refreshToken: String?) async {
        let registration = pendingSignOut
        pendingSignOut = nil
        guard let registration, let accessToken, let refreshToken else { return }
        let previous = publicationTask
        let cleanup = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            // A completed re-sign-in supersedes this old session's withdrawal.
            // Any later publication waits on this cleanup through the same lane.
            if let identity = self.auth?.authenticatedSessionIdentity,
               identity.accountID == registration.accountID,
               identity.generation != registration.generation,
               !self.signingOut { return }
            if self.lastRegistration == registration { self.lastRegistration = nil }
            var withdrawn = registration
            withdrawn.routes = []
            _ = await self.publish(withdrawn, tokens: (accessToken, refreshToken))
        }
        publicationTask = cleanup
        await withTaskCancellationHandler {
            await cleanup.value
        } onCancel: {
            cleanup.cancel()
        }
    }

    private func registerCurrentState(renewLease: Bool) async {
        guard !signingOut, let auth else { return }
        let snapshot: AuthenticatedSessionSnapshot
        do { snapshot = try await auth.authenticatedSessionSnapshot() } catch { return }
        guard !signingOut,
              auth.authenticatedSessionIdentity == AuthenticatedSessionIdentity(
                generation: snapshot.generation, accountID: snapshot.accountID
              ) else { return }
        let teamID = auth.resolvedTeamID
        let incomingAllowed = MobileRemoteControlPolicy.allowsIncomingAccess()
        let routes = incomingAllowed ? latestRoutes : []
        let current = Registration(
            teamID: teamID, tag: MobileHostIdentity.instanceTag(), routes: routes,
            accountID: snapshot.accountID, generation: snapshot.generation
        )
        let tokens = (accessToken: snapshot.accessToken, refreshToken: snapshot.refreshToken)
        if let previous = lastRegistration,
           previous.accountID == snapshot.accountID,
           previous.teamID != current.teamID {
            var withdrawn = previous
            withdrawn.routes = []
            _ = await publish(withdrawn, tokens: tokens)
            lastRegistration = nil
        }
        if lastRegistration?.accountID != snapshot.accountID { lastRegistration = nil }
        guard !signingOut,
              auth.authenticatedSessionIdentity == AuthenticatedSessionIdentity(
                generation: snapshot.generation, accountID: snapshot.accountID
              ), auth.resolvedTeamID == teamID else { return }
        let renew = renewLease && !routes.isEmpty && Self.leaseRenewalDue(lastSuccess: lastLeaseRenewal, now: .now)
        let withdrawUnknownRegistration = !incomingAllowed && lastRegistration == nil
        guard Self.shouldReRegister(previous: lastRegistration, current: current) || renew || withdrawUnknownRegistration else { return }
        // Withdrawals must not be suppressed by a previous positive publication's backoff.
        if !routes.isEmpty, await retryAfterGate.remainingSeconds() != nil { return }
        if await publish(current, tokens: tokens) {
            lastRegistration = current
            if !routes.isEmpty { lastLeaseRenewal = .now }
        }
    }

    private func publish(
        _ registration: Registration,
        tokens: (accessToken: String, refreshToken: String)
    ) async -> Bool {
        activePublication = registration
        defer { if activePublication == registration { activePublication = nil } }
        guard var comps = URLComponents(
            url: AuthEnvironment.deviceRegistryAPIBaseURL, resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/devices"
        guard let url = comps.url else { return false }

        let disclosureDate = Date()
        var bodyDict: [String: Any] = [
            "deviceId": MobileHostIdentity.deviceID(),
            "tag": registration.tag
        ]
        if !registration.routes.isEmpty {
            bodyDict["platform"] = "mac"
            bodyDict["discoveryLease"] = true
            bodyDict["routes"] = registration.routes.mobileHostJSONObjects(
                for: .cloudRendezvous,
                at: disclosureDate
            )
            if let displayName = MobileHostIdentity.baseDisplayName(), !displayName.isEmpty {
                bodyDict["displayName"] = displayName
            }
        }

        var req = URLRequest(url: url)
        req.httpMethod = registration.routes.isEmpty ? "PATCH" : "POST"
        req.timeoutInterval = 2
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID = registration.teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict, options: [])

        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    // Only remember the scope once the server accepted it, so a
                    // transient failure retries on the next status tick.
                    return true
                } else {
                    if http.statusCode == 429 {
                        let seconds = CmxRetryAfterPolicy.seconds(
                            from: http,
                            defaultSeconds: CmxRetryAfterPolicy.defaultRateLimitSeconds
                        ) ?? CmxRetryAfterPolicy.defaultRateLimitSeconds
                        await retryAfterGate.extend(by: seconds)
                    }
                    NSLog("cmux.deviceRegistry register failed status=%d", http.statusCode)
                }
            }
        } catch {
            // Best-effort; the registry must never disrupt the Mac. Still log:
            // a silently unreachable registry strands every paired phone on
            // stale routes with nothing to diagnose from.
            NSLog("cmux.deviceRegistry register unreachable: %@", String(describing: type(of: error)))
        }
        return false
    }

}
