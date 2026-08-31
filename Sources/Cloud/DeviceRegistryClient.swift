import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

/// Registers this Mac (and its running cmux app instance's attach routes) in the
/// team-scoped device registry (`POST /api/devices`), so a phone can look up the
/// Mac's current routes on reload and auto-pair instead of re-scanning a QR.
///
/// Event-driven: it observes ``MobileHostService/statusUpdates()`` and registers
/// whenever the advertised route set changes (e.g. the Mac moved networks or
/// rebound to a different port), which is exactly the freshness the phone needs.
/// It also observes auth state, so a sign-in registers immediately with the
/// cached routes, a team switch moves the registration (tag-scoped DELETE from
/// the old team, POST into the new one), and a sign-out removes this instance
/// from every team it registered into: the registry is the phone's source of
/// truth for membership, so a signed-out Mac must not linger in it.
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
    private let defaults = UserDefaults.standard
    private var auth: AuthCoordinator?
    private var observeTask: Task<Void, Never>?
    private let authObserver = CloudAuthStateObserver()
    private var authObserveTask: Task<Void, Never>?
    /// The last auth scope the observer yielded; `nil` until the first yield,
    /// which is treated as a baseline (the route-driven path owns initial
    /// registration) rather than a transition.
    private var lastAuthState: CloudAuthObservedState?
    /// The routes most recently advertised by ``MobileHostService``, cached so
    /// auth transitions (sign-in, team switch) can register immediately instead
    /// of waiting for the next status tick. Same pattern as
    /// ``PresenceHeartbeatClient``'s route cache.
    private var currentRoutes: [CmxAttachRoute] = []
    /// The scope (team + tag + routes + name) most recently registered, used to
    /// skip redundant POSTs. Keyed on the full scope rather than routes alone
    /// so an account/team switch with unchanged routes still re-registers in
    /// the newly selected team instead of being deduped away.
    private var lastRegistration: Registration?

    /// The identity of a registration POST, for deduplication.
    struct Registration: Equatable {
        var teamID: String?
        var tag: String
        var routes: [CmxAttachRoute]
        /// The device display name sent with the POST. Part of the key so a
        /// rename re-registers on the next tick instead of never.
        var displayName: String?
    }

    private init() {}

    /// Inject the auth dependency and begin observing host-route and auth
    /// changes. Call once at the composition root (after `auth` is
    /// constructed).
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        startObserving()
        startObservingAuth()
    }

    /// Whether a registration with `current` scope differs from what was last
    /// registered, and therefore should be POSTed.
    ///
    /// Pure so it is unit-testable without any network or host service.
    ///
    /// Fires (returns `true`) when the team, tag, routes, or display name
    /// differ from the last registration. The team is part of the key so an
    /// account/team switch with unchanged routes still registers in the new
    /// team; the display name is part of the key so a rename propagates on the
    /// next tick. The routes-empty transition (the user turned mobile pairing
    /// off) also fires once, so the registry stops advertising stale routes;
    /// the phone already skips empty-route instances. An unchanged scope (a
    /// connection-only `statusUpdates()` tick) and the never-registered empty
    /// start (`nil` previous with empty routes) are both no-ops, so the
    /// off-state is published exactly once rather than on every empty tick.
    nonisolated static func shouldReRegister(
        previous: Registration?,
        current: Registration
    ) -> Bool {
        // Treat "never registered" as an empty-routes baseline in the same scope
        // so an initial empty set (pairing off at launch) is a no-op, but a later
        // clear, or any team/tag change, still fires.
        let baseline = previous ?? Registration(
            teamID: current.teamID,
            tag: current.tag,
            routes: [],
            displayName: current.displayName
        )
        return baseline != current
    }

    // MARK: - Registered-team bookkeeping

    /// The registry has no "list my registrations" read this client could use
    /// after the token store is cleared, so every successful POST records its
    /// team here and every successful sign-out DELETE removes it. Keyed by tag
    /// so parallel tagged dev builds sharing `UserDefaults.standard` never
    /// deregister each other's instance rows.
    nonisolated static func registeredTeamsDefaultsKey(tag: String) -> String {
        "cmux.deviceRegistry.registeredTeams.\(tag)"
    }

    /// A registration can resolve to no explicit team (the server then targets
    /// the caller's default team). The persisted set stores that as an empty
    /// marker so the sign-out DELETE replays the same "no `X-Cmux-Team-Id`
    /// header" request the POST made.
    nonisolated static func teamMarker(_ teamID: String?) -> String {
        teamID ?? ""
    }

    /// Pure set insert over the persisted marker array (sorted + deduped so
    /// the stored value is deterministic).
    nonisolated static func addingTeamMarker(_ marker: String, to markers: [String]) -> [String] {
        var set = Set(markers)
        set.insert(marker)
        return set.sorted()
    }

    /// Pure set removal over the persisted marker array.
    nonisolated static func removingTeamMarker(_ marker: String, from markers: [String]) -> [String] {
        markers.filter { $0 != marker }.sorted()
    }

    private func readRegisteredTeamMarkers() -> [String] {
        defaults.stringArray(
            forKey: Self.registeredTeamsDefaultsKey(tag: MobileHostIdentity.instanceTag())
        ) ?? []
    }

    private func writeRegisteredTeamMarkers(_ markers: [String]) {
        let key = Self.registeredTeamsDefaultsKey(tag: MobileHostIdentity.instanceTag())
        if markers.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(markers, forKey: key)
        }
    }

    private func recordRegisteredTeam(_ teamID: String?) {
        writeRegisteredTeamMarkers(
            Self.addingTeamMarker(Self.teamMarker(teamID), to: readRegisteredTeamMarkers())
        )
    }

    private func removeRegisteredTeamMarker(_ marker: String) {
        writeRegisteredTeamMarkers(
            Self.removingTeamMarker(marker, from: readRegisteredTeamMarkers())
        )
    }

    // MARK: - Observation

    private func startObserving() {
        observeTask?.cancel()
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                guard let self else { break }
                self.currentRoutes = status.routes
                await self.registerCurrentScope()
            }
        }
    }

    /// React to auth transitions the route stream cannot see: registration is
    /// otherwise driven only by host-route changes, so without this a sign-in
    /// or mid-session team switch with unchanged routes would wait for the
    /// next status tick (or never re-register at all after a sign-out
    /// deregistration).
    private func startObservingAuth() {
        guard let auth else { return }
        authObserveTask?.cancel()
        lastAuthState = nil
        let states = authObserver.states(for: auth)
        authObserveTask = Task { @MainActor [weak self] in
            for await state in states {
                if Task.isCancelled { break }
                guard let self else { break }
                await self.handleAuthState(state)
            }
        }
    }

    private func handleAuthState(_ state: CloudAuthObservedState) async {
        let previous = lastAuthState
        lastAuthState = state
        guard let previous, previous != state else { return }
        if state.isAuthenticated, !previous.isAuthenticated || previous.userID != state.userID {
            // A fresh session (sign-in, or account switch): the sign-out
            // deregistration removed this instance's row, so force a POST with
            // the cached routes instead of waiting for the next route tick.
            lastRegistration = nil
            await registerCurrentScope()
        } else if state.isAuthenticated, previous.isAuthenticated, previous.teamID != state.teamID {
            await moveRegistration(from: previous.teamID)
        } else if !state.isAuthenticated, previous.isAuthenticated {
            // Sign-out observed without the flow hooks: no tokens survive
            // here, so no DELETE is possible. The interactive flow's
            // `onSignedOut` and the coordinator's `onSessionInvalidated`
            // backstop call ``deregisterForSignOut(accessToken:refreshToken:)``
            // with the captured pre-clear pair. Only reset the dedup key so
            // the next sign-in re-registers.
            lastRegistration = nil
        }
    }

    /// Mid-session team switch: remove this instance's row from the team it
    /// leaves (the current tokens still authorize it) and register into the
    /// newly resolved team immediately.
    private func moveRegistration(from oldTeamID: String?) async {
        if let auth, let tokens = try? await auth.currentTokens() {
            await sendDeregistration(
                teamMarker: Self.teamMarker(oldTeamID),
                accessToken: tokens.accessToken,
                refreshToken: tokens.refreshToken
            )
        }
        lastRegistration = nil
        await registerCurrentScope()
    }

    // MARK: - Registration

    private func registerCurrentScope() async {
        guard let auth else { return }
        // Await tokens FIRST: this both gates on "signed in" and waits for launch
        // auth bootstrap. `resolvedTeamID` is derived from `availableTeams`, which
        // is empty until bootstrap completes, so reading the team before this
        // await could resolve nil even when the user has a persisted selected team
        // and publish the Mac into the wrong (Stack-default) team. After bootstrap
        // `currentTokens()` returns the cached token, so awaiting it per tick is
        // cheap.
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return // not signed in → nothing to do
        }
        // Resolve the team AFTER bootstrap, and use that same scope for both the
        // dedup decision and the request header, so a team switch with unchanged
        // routes is detected and the POST targets the intended team.
        let teamID = auth.resolvedTeamID
        let tag = MobileHostIdentity.instanceTag()
        // Never empty: ``MobileHostIdentity/baseDisplayName()`` returns nil
        // for a blank name, so the dedup key and the body agree.
        let displayName = MobileHostIdentity.baseDisplayName()
        let registration = Registration(
            teamID: teamID,
            tag: tag,
            routes: currentRoutes,
            displayName: displayName
        )
        guard Self.shouldReRegister(previous: lastRegistration, current: registration) else { return }

        guard let url = Self.devicesEndpointURL() else { return }

        let disclosureDate = Date()
        var bodyDict: [String: Any] = [
            "deviceId": MobileHostIdentity.deviceID(),
            "platform": "mac",
            "tag": tag,
            "routes": registration.routes.mobileHostJSONObjects(
                for: .cloudRendezvous,
                at: disclosureDate
            ),
        ]
        if let displayName {
            bodyDict["displayName"] = displayName
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict, options: [])

        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    // Only remember the scope once the server accepted it, so a
                    // transient failure retries on the next status tick. The
                    // persisted team set is what sign-out later deregisters.
                    lastRegistration = registration
                    recordRegisteredTeam(teamID)
                } else {
                    NSLog("cmux.deviceRegistry register failed status=%d", http.statusCode)
                }
            }
        } catch {
            // best-effort; registry must never disrupt the Mac.
        }
    }

    // MARK: - Sign-out deregistration

    /// Remove this app instance from every team it registered into, using the
    /// pre-clear token pair captured by the sign-out flow (or the
    /// coordinator's invalidation backstop); by the time this runs the live
    /// token store is already empty. Tag-scoped: only this instance's row is
    /// deleted, so a Nightly and a Stable on the same Mac sign out
    /// independently. Best-effort with short timeouts and never throws;
    /// markers whose DELETE fails stay persisted and are retried on the next
    /// sign-out.
    func deregisterForSignOut(accessToken: String?, refreshToken: String?) async {
        // A registration this session may have targeted a team resolved after
        // the persisted set was last written; fold it in before clearing the
        // dedup key.
        var markers = readRegisteredTeamMarkers()
        if let lastRegistration {
            markers = Self.addingTeamMarker(Self.teamMarker(lastRegistration.teamID), to: markers)
        }
        lastRegistration = nil
        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              let refreshToken = refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return
        }
        for marker in markers {
            await sendDeregistration(
                teamMarker: marker,
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        }
    }

    /// One tag-scoped `DELETE /api/devices` against one team. Removes the
    /// team's marker from the persisted set only on a 2xx, so an unreachable
    /// registry keeps the marker for a later retry.
    private func sendDeregistration(
        teamMarker: String,
        accessToken: String,
        refreshToken: String
    ) async {
        guard let url = Self.devicesEndpointURL() else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        // Short: sign-out's bounded teardown window covers this call plus the
        // presence goodbye, and a hung registry must not eat that budget.
        req.timeoutInterval = 4
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if !teamMarker.isEmpty {
            req.setValue(teamMarker, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "deviceId": MobileHostIdentity.deviceID(),
                "tag": MobileHostIdentity.instanceTag(),
            ],
            options: []
        )
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse {
                if (200...299).contains(http.statusCode) {
                    removeRegisteredTeamMarker(teamMarker)
                } else {
                    NSLog("cmux.deviceRegistry deregister failed status=%d", http.statusCode)
                }
            }
        } catch {
            // best-effort; sign-out must never be held hostage by the registry.
        }
    }

    private nonisolated static func devicesEndpointURL() -> URL? {
        guard var comps = URLComponents(
            url: AuthEnvironment.vmAPIBaseURL,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/devices"
        return comps.url
    }

}
