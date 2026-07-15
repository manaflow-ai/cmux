import CMUXMobileCore
import CmuxAuthRuntime
import CmuxFoundation
import Foundation

extension Notification.Name {
    /// One workspace's discovery summary may have changed; consumers coalesce affected workspace ids.
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

    nonisolated static let maximumRequestBytes = 64 * 1024
    /// Leaves half of the server's 64 KiB request limit for routes and envelope fields.
    nonisolated static let maximumLiveSessionPayloadBytes = 32 * 1024

    private let session = CmxCredentialedHTTPSession()
    /// Activity bursts settle after one second but sustained hooks flush at least every five seconds.
    private let liveSessionInvalidationBatcher: LatestWinsBatcher<String?, Bool>
    private var auth: AuthCoordinator?
    private var liveSessions: @MainActor (String?) -> [CmxLiveSession] = { _ in [] }
    private var routeObserveTask: Task<Void, Never>?
    private var liveSessionObserveTask: Task<Void, Never>?
    private var latestRoutes: [CmxAttachRoute] = []
    private var liveSessionsByWorkspaceID: [String: [CmxLiveSession]] = [:]
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

    private init() {
        liveSessionInvalidationBatcher = LatestWinsBatcher(
            quietDelay: 1,
            maximumDelay: 5
        )
    }

    /// Inject the auth dependency and begin observing host-route changes. Call
    /// once at the composition root (after `auth` is constructed).
    func configure(
        auth: AuthCoordinator,
        liveSessions: @escaping @MainActor (String?) -> [CmxLiveSession]
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
        guard !routes.isEmpty else { return [] }
        var payloadBytes = 2 // JSON array brackets.
        var advertised: [CmxLiveSession] = []

        for session in sessions
            .sorted(by: Self.liveSessionSort)
            .prefix(50) {
            guard let bounded = Self.registryBoundedSession(session),
                  let encoded = try? JSONEncoder().encode(bounded) else {
                continue
            }
            let candidateBytes = payloadBytes + encoded.count + (advertised.isEmpty ? 0 : 1)
            guard candidateBytes <= maximumLiveSessionPayloadBytes else { break }
            payloadBytes = candidateBytes
            advertised.append(bounded)
        }
        return advertised
    }

    nonisolated static func registrationBody(
        deviceID: String,
        tag: String,
        routes: [CmxAttachRoute],
        sessions: [CmxLiveSession],
        displayName: String?,
        disclosureDate: Date = Date()
    ) -> Data? {
        var body: [String: Any] = [
            "deviceId": deviceID,
            "platform": "mac",
            "tag": tag,
            "routes": routes.mobileHostJSONObjects(
                for: .cloudRendezvous,
                at: disclosureDate
            ),
        ]
        if let encodedSessions = try? JSONEncoder().encode(sessions),
           let sessionObjects = try? JSONSerialization.jsonObject(with: encodedSessions) {
            body["sessions"] = sessionObjects
        }
        if let displayName, !displayName.isEmpty {
            body["displayName"] = displayName
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              data.count <= maximumRequestBytes else {
            return nil
        }
        return data
    }

    private func startObserving() {
        routeObserveTask?.cancel()
        liveSessionObserveTask?.cancel()
        routeObserveTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                guard let self else { break }
                let previouslyAdvertisedRoutes = !self.latestRoutes.isEmpty
                self.latestRoutes = status.routes
                if self.latestRoutes.isEmpty {
                    self.liveSessionInvalidationBatcher.cancel()
                    self.liveSessionsByWorkspaceID.removeAll(keepingCapacity: true)
                } else if !previouslyAdvertisedRoutes {
                    self.rebuildLiveSessionSnapshot()
                }
                await self.requestRegistration()
            }
        }
        liveSessionObserveTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .cmuxLiveSessionsDidChange) {
                if Task.isCancelled { break }
                self?.scheduleLiveSessionRefresh(workspaceID: notification.object as? String)
            }
        }
    }

    private func scheduleLiveSessionRefresh(workspaceID: String?) {
        guard !latestRoutes.isEmpty else { return }
        liveSessionInvalidationBatcher.submit(true, for: workspaceID) { [weak self] invalidations in
            guard let self, !self.latestRoutes.isEmpty else { return }
            self.refreshLiveSessionSnapshot(invalidations: Set(invalidations.keys))
            Task { @MainActor [weak self] in
                await self?.requestRegistration()
            }
        }
    }

    private func refreshLiveSessionSnapshot(invalidations: Set<String?>) {
        if invalidations.contains(nil) {
            rebuildLiveSessionSnapshot()
            return
        }
        for invalidation in invalidations {
            guard let workspaceID = invalidation else { continue }
            let replacement = liveSessions(workspaceID).filter { $0.workspaceID == workspaceID }
            if replacement.isEmpty {
                liveSessionsByWorkspaceID.removeValue(forKey: workspaceID)
            } else {
                liveSessionsByWorkspaceID[workspaceID] = replacement
            }
        }
    }

    private func rebuildLiveSessionSnapshot() {
        liveSessionsByWorkspaceID = Dictionary(grouping: liveSessions(nil), by: \.workspaceID)
    }

    private var liveSessionSnapshot: [CmxLiveSession] {
        liveSessionsByWorkspaceID.values
            .flatMap { $0 }
            .sorted(by: Self.liveSessionSort)
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
        let sessions = Self.advertisedSessions(routes: latestRoutes, sessions: liveSessionSnapshot)
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

        let deviceID = MobileHostIdentity.deviceID()
        let displayName = MobileHostIdentity.baseDisplayName()
        let disclosureDate = Date()
        guard let body = Self.registrationBody(
            deviceID: deviceID,
            tag: tag,
            routes: registration.routes,
            sessions: registration.sessions,
            displayName: displayName,
            disclosureDate: disclosureDate
        ) ?? Self.registrationBody(
            deviceID: deviceID,
            tag: tag,
            routes: registration.routes,
            sessions: [],
            displayName: displayName,
            disclosureDate: disclosureDate
        ) else {
            return
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
        req.httpBody = body

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

    private nonisolated static func liveSessionSort(_ lhs: CmxLiveSession, _ rhs: CmxLiveSession) -> Bool {
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        return lhs.id < rhs.id
    }

    private nonisolated static func registryBoundedSession(_ session: CmxLiveSession) -> CmxLiveSession? {
        guard let id = boundedString(session.id, maximumScalars: 128),
              let workspaceID = boundedString(session.workspaceID, maximumScalars: 128),
              let title = boundedString(session.title, maximumScalars: 160),
              session.lastActivityAt.isFinite,
              (0...253_402_300_799).contains(session.lastActivityAt) else {
            return nil
        }
        return CmxLiveSession(
            id: id,
            workspaceID: workspaceID,
            terminalID: session.terminalID.flatMap { boundedString($0, maximumScalars: 128) },
            agentSessionID: session.agentSessionID.flatMap { boundedString($0, maximumScalars: 128) },
            title: title,
            agent: session.agent.flatMap { boundedString($0, maximumScalars: 32) },
            status: session.status,
            lastActivityAt: session.lastActivityAt
        )
    }

    private nonisolated static func boundedString(_ value: String, maximumScalars: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.unicodeScalars.prefix(maximumScalars))
    }

}
