import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

extension Notification.Name {
    /// A workspace or preferred agent summary changed materially enough to refresh discovery.
    static let cmuxLiveSessionsDidChange = Notification.Name("com.cmuxterm.registry.live-sessions-changed")
}

/// Registers this Mac (and its running cmux app instance's attach routes) in the
/// team-scoped device registry (`POST /api/devices`), so a phone can look up the
/// Mac's current routes on reload and auto-pair instead of re-scanning a QR.
///
/// Event-driven: it observes ``MobileHostService/statusUpdates()`` and the live
/// workspace/session projection, registering whenever either advertised routes
/// or the bounded session summaries change.
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

    private let session: URLSession = .shared
    private let liveSessionRefreshDelay: Duration = .seconds(1)
    private var auth: AuthCoordinator?
    private var liveSessions: @MainActor () -> [CmxLiveSession] = { [] }
    private var routeObserveTask: Task<Void, Never>?
    private var liveSessionObserveTask: Task<Void, Never>?
    private var liveSessionRefreshTask: Task<Void, Never>?
    private var latestRoutes: [CmxAttachRoute] = []
    private var registrationInFlight = false
    private var registrationPending = false
    /// The scope (team + tag + routes + sessions) most recently registered, used to skip
    /// redundant POSTs. Keyed on the full scope rather than routes alone so an
    /// account/team switch with unchanged routes still re-registers in the newly
    /// selected team instead of being deduped away.
    private var lastRegistration: Registration?

    /// The identity of a registration POST, for deduplication.
    struct Registration: Equatable {
        var teamID: String?
        var tag: String
        var routes: [CmxAttachRoute]
        var sessions: [CmxLiveSession]
    }

    private init() {}

    /// Inject the auth dependency and begin observing host-route changes. Call
    /// once at the composition root (after `auth` is constructed).
    func configure(
        auth: AuthCoordinator,
        liveSessions: @escaping @MainActor () -> [CmxLiveSession]
    ) {
        self.auth = auth
        self.liveSessions = liveSessions
        startObserving()
    }

    /// Whether a registration with `current` scope differs from what was last
    /// registered, and therefore should be POSTed.
    ///
    /// Pure so it is unit-testable without any network or host service.
    ///
    /// Fires (returns `true`) when the team, tag, routes, or session summaries differ from the last
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
            teamID: current.teamID,
            tag: current.tag,
            routes: [],
            sessions: []
        )
        return baseline != current
    }

    /// Sessions are discoverable only while the same registration advertises a
    /// reachable host route. Turning mobile pairing off clears both together.
    nonisolated static func advertisedSessions(
        routes: [CmxAttachRoute],
        sessions: [CmxLiveSession]
    ) -> [CmxLiveSession] {
        routes.isEmpty ? [] : Array(sessions.prefix(50))
    }

    private func startObserving() {
        routeObserveTask?.cancel()
        liveSessionObserveTask?.cancel()
        routeObserveTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                guard let self else { break }
                self.latestRoutes = status.routes
                await self.requestRegistration()
            }
        }
        liveSessionObserveTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .cmuxLiveSessionsDidChange) {
                if Task.isCancelled { break }
                self?.scheduleLiveSessionRefresh()
            }
        }
    }

    private func scheduleLiveSessionRefresh() {
        liveSessionRefreshTask?.cancel()
        liveSessionRefreshTask = Task { @MainActor [weak self, liveSessionRefreshDelay] in
            // Intentional cancellable debounce: hook/tool bursts should publish
            // one final discovery snapshot, not one cloud POST per hook event.
            try? await Task.sleep(for: liveSessionRefreshDelay)
            guard !Task.isCancelled, let self else { return }
            await self.requestRegistration()
        }
    }

    /// Serialize route- and session-driven writes through one mutation path. If
    /// state changes during a POST, one trailing pass publishes the newest state.
    private func requestRegistration() async {
        registrationPending = true
        guard !registrationInFlight else { return }
        registrationInFlight = true
        defer { registrationInFlight = false }
        while registrationPending {
            registrationPending = false
            await registerCurrentState()
        }
    }

    private func registerCurrentState() async {
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
        let sessions = Self.advertisedSessions(routes: latestRoutes, sessions: liveSessions())
        let registration = Registration(
            teamID: teamID,
            tag: tag,
            routes: latestRoutes,
            sessions: sessions
        )
        guard Self.shouldReRegister(previous: lastRegistration, current: registration) else { return }

        guard var comps = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            return
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/devices"
        guard let url = comps.url else { return }

        var bodyDict: [String: Any] = [
            "deviceId": MobileHostIdentity.deviceID(),
            "platform": "mac",
            "tag": tag,
            "routes": registration.routes.map(\.mobileHostJSONObject),
        ]
        if let encodedSessions = try? JSONEncoder().encode(registration.sessions),
           let sessionObjects = try? JSONSerialization.jsonObject(with: encodedSessions) {
            bodyDict["sessions"] = sessionObjects
        }
        if let displayName = MobileHostIdentity.baseDisplayName(), !displayName.isEmpty {
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
                    // transient failure retries on the next status tick.
                    lastRegistration = registration
                } else {
                    NSLog("cmux.deviceRegistry register failed status=%d", http.statusCode)
                }
            }
        } catch {
            // best-effort; registry must never disrupt the Mac.
        }
    }

}
