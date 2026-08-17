import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

/// Announces this Mac's running cmux app instance to the team-scoped presence
/// service (`POST /v1/presence/heartbeat` on `workers/presence`), so phones and
/// other team devices can see it flip online/offline live.
///
/// Follows the ``DeviceRegistryClient`` registry-refresh pattern: same device
/// identity (``MobileHostIdentity/deviceID()``), same build tag, same
/// best-effort posture (a presence outage never disturbs the Mac). Where the
/// registry POSTs on route *changes* (durable rendezvous data), presence is a
/// liveness signal, so this client POSTs on a steady cadence. The cadence is
/// server-owned: every heartbeat response carries `heartbeatIntervalMs`, and
/// the loop sleeps that long, so the server can retune without a client ship.
///
/// Every beat also states the host's full current attach-route set (the same
/// set ``DeviceRegistryClient`` writes through to the durable registry), and a
/// route change additionally triggers one immediate out-of-cadence beat, so
/// the presence service can push the fresh port/IP to subscribed phones live.
///
/// Offline is explicit on the server: a clean quit sends a `stopping: true`
/// goodbye; a crash or sleep is caught by the service's missed-heartbeat alarm
/// (45s), so this client never needs a watchdog of its own.
@MainActor
final class PresenceHeartbeatClient {
    static let shared = PresenceHeartbeatClient()

    private struct HeartbeatIdentity: Sendable {
        let teamID: String?
        let deviceID: String
        let tag: String
        let lifecycleID: String
        let bundleID: String?
        let displayName: String?
        let routes: [CmxAttachRoute]
    }

    private let session: URLSession = .shared
    private var auth: AuthCoordinator?
    private var loopTask: Task<Void, Never>?
    private var routesObserveTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    /// Invalidates a heartbeat that was suspended across an auth transition.
    /// This is a lifecycle generation, not a retry counter: a stale normal beat
    /// must never race a signed-out goodbye and re-add the Mac.
    private var lifecycleGeneration: UInt64 = 0
    /// Random fence for one signed-in app lifecycle. It is deliberately stable
    /// across access-token refreshes and replaced only when auth signs in again.
    private var activeLifecycleID: String?
    private var pendingSignOutIdentity: HeartbeatIdentity?
    /// Most recent successfully announced scope plus any older team scopes
    /// awaiting an explicit removal. This makes team switching live in both
    /// directions even when the first cleanup request hits a transient outage.
    private var lastAnnouncedIdentity: HeartbeatIdentity?
    private var pendingDepartureIdentities: [HeartbeatIdentity] = []
    /// Cadence between heartbeats; server-owned, seeded with the service default.
    private var intervalMs: Int = 15_000
    /// The attach routes most recently advertised by ``MobileHostService``,
    /// included in every heartbeat so the presence service mirrors the same
    /// set the device registry stores (DO = live cache, registry = truth).
    private var currentRoutes: [CmxAttachRoute] = []

    private init() {}

    /// Inject the auth dependency and start (or arm) the heartbeat loop. Call
    /// once at the composition root, alongside ``DeviceRegistryClient``.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        startObservingRoutes()
        if defaultsObserver == nil {
            // Re-evaluate when the flag or URL flips, so enabling presence in a
            // running app starts the loop without a relaunch (and disabling
            // stops it and says goodbye).
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    PresenceHeartbeatClient.shared.evaluate()
                }
            }
        }
        if auth.isAuthenticated {
            if activeLifecycleID == nil {
                activeLifecycleID = Self.makeLifecycleID()
            }
            restartLoop()
        } else {
            evaluate()
        }
    }

    /// Called by the auth composition after a session is published. Restarting
    /// the loop makes the first authenticated heartbeat immediate, so a phone
    /// does not wait for the previous cadence interval to discover this Mac.
    func authDidSignIn() {
        pendingSignOutIdentity = nil
        activeLifecycleID = Self.makeLifecycleID()
        restartLoop()
    }

    /// Wake the heartbeat loop when Settings changes the selected team. The
    /// next immediate beat removes the previous team scope before announcing
    /// the new one, then retries either side independently on later cadences.
    func authTeamDidChange() {
        restartLoop()
    }

    /// Capture the pre-clear identity and stop ordinary beats before
    /// ``AuthCoordinator.signOut`` destroys local credentials. The captured
    /// identity is used by ``sendSignedOut`` with the teardown token supplied by
    /// the coordinator after its local-first clear.
    func prepareForSignOut() {
        lifecycleGeneration &+= 1
        let current = currentIdentity()
        if let lastAnnouncedIdentity,
           current.map({ !Self.samePresenceScope(lastAnnouncedIdentity, $0) }) ?? true,
           !pendingDepartureIdentities.contains(where: {
               Self.samePresenceScope($0, lastAnnouncedIdentity)
           }) {
            pendingDepartureIdentities.append(lastAnnouncedIdentity)
            trimPendingDepartures()
        }
        pendingSignOutIdentity = current ?? lastAnnouncedIdentity
        activeLifecycleID = nil
        stopLoop()
    }

    /// Send the authenticated sign-out marker after local auth state has been
    /// cleared. The worker removes this instance from the synced device list
    /// immediately while retaining a short presence record for safe re-sign-in.
    func sendSignedOut(accessToken: String?) async {
        guard let accessToken else { return }
        let identity = pendingSignOutIdentity
        pendingSignOutIdentity = nil
        if let identity,
           !pendingDepartureIdentities.contains(where: {
               Self.samePresenceScope($0, identity)
           }) {
            pendingDepartureIdentities.append(identity)
            trimPendingDepartures()
        }
        let identities = pendingDepartureIdentities
        guard !identities.isEmpty else { return }
        for departure in identities {
            await sendHeartbeat(
                stopping: true,
                signedOut: true,
                explicitAccessToken: accessToken,
                explicitIdentity: departure
            )
        }
    }

    /// Cancel the loop and send a best-effort goodbye. Called from
    /// `applicationWillTerminate`; the process may exit before the request
    /// lands, which is fine: the service's missed-heartbeat timeout covers
    /// every unclean path, the goodbye only makes clean quits flip offline
    /// immediately instead of within 45s.
    func appWillTerminate() {
        guard loopTask != nil else { return }
        lifecycleGeneration &+= 1
        stopLoop()
        Task { await self.sendHeartbeat(stopping: true) }
    }

    // MARK: - Routes

    /// Mirror ``DeviceRegistryClient``'s observation of the host's advertised
    /// attach routes. Where the registry client POSTs durable rendezvous data
    /// on change, presence carries the same set on every heartbeat — and a
    /// change triggers one immediate out-of-cadence beat so subscribed phones
    /// receive the fresh port/IP within a round trip instead of waiting out
    /// the 15s cadence.
    private func startObservingRoutes() {
        guard routesObserveTask == nil else { return }
        routesObserveTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                guard let self, !Task.isCancelled else { break }
                guard self.currentRoutes != status.routes else { continue }
                self.currentRoutes = status.routes
                // Push the change live only while the heartbeat loop runs; a
                // disabled client stays silent and the cached set rides the
                // first beat whenever the loop starts.
                if self.loopTask != nil {
                    self.restartLoop()
                }
            }
        }
    }

    // MARK: - Loop lifecycle

    private var isEnabled: Bool {
        PresenceSettings.isEnabled()
    }

    /// Resolved service base URL: env override first (dev/tagged builds), then
    /// the defaults key, then the Debug-build dev-instance default. Nil
    /// disables the client entirely.
    static func resolvedServiceURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> URL? {
        var raw = environment[PresenceSettings.serviceURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? defaults.string(forKey: PresenceSettings.serviceURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if raw == nil || raw?.isEmpty == true {
            #if DEBUG
            // Debug builds authenticate against the dev Stack project, which is
            // what the dev/staging worker verifies — see PresenceSettings.
            raw = PresenceSettings.debugDefaultServiceURL
            #else
            // Release builds talk to the production presence worker, so stable
            // cmux announces presence once mobile is enabled (gated by isEnabled).
            raw = PresenceSettings.productionServiceURL
            #endif
        }
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func evaluate() {
        let shouldRun = auth?.isAuthenticated == true
            && isEnabled
            && Self.resolvedServiceURL() != nil
        if shouldRun && loopTask == nil {
            startLoop()
        } else if !shouldRun, loopTask != nil {
            lifecycleGeneration &+= 1
            stopLoop()
            // Flag turned off while running: announce the disappearance instead
            // of leaving the instance to time out.
            Task { await self.sendHeartbeat(stopping: true) }
        }
    }

    private func startLoop() {
        let generation = lifecycleGeneration
        loopTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self,
                      self.lifecycleGeneration == generation,
                      self.auth?.isAuthenticated == true else { return }
                await self.sendHeartbeat(stopping: false, generation: generation)
                let interval = self.intervalMs
                // Bounded, cancellable, intended cadence delay (the heartbeat
                // interval itself, server-owned); cancellation is wired to
                // stopLoop()/appWillTerminate via this task.
                guard (try? await clock.sleep(for: .milliseconds(interval))) != nil else { return }
            }
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Cancel the current cadence and begin a fresh one. This is the shared
    /// wake-up path for sign-in and route changes, so every lifecycle edge uses
    /// one heartbeat loop instead of spawning competing detached requests.
    private func restartLoop() {
        lifecycleGeneration &+= 1
        stopLoop()
        evaluate()
    }

    private func currentIdentity() -> HeartbeatIdentity? {
        guard let auth, let activeLifecycleID else { return nil }
        return HeartbeatIdentity(
            teamID: auth.resolvedTeamID,
            deviceID: MobileHostIdentity.deviceID(),
            tag: MobileHostIdentity.instanceTag(),
            lifecycleID: activeLifecycleID,
            bundleID: Bundle.main.bundleIdentifier,
            displayName: MobileHostIdentity.instanceDisplayName(),
            routes: currentRoutes
        )
    }

    // MARK: - Heartbeat

    private func sendHeartbeat(
        stopping: Bool,
        signedOut: Bool = false,
        generation: UInt64? = nil,
        explicitAccessToken: String? = nil,
        explicitIdentity: HeartbeatIdentity? = nil
    ) async {
        let accessToken: String
        let identity: HeartbeatIdentity
        if let explicitAccessToken, let explicitIdentity {
            accessToken = explicitAccessToken
            identity = explicitIdentity
        } else {
            guard let auth, auth.isAuthenticated,
                  let currentIdentity = currentIdentity() else { return }
            // Await tokens first, mirroring DeviceRegistryClient: this gates on
            // launch auth bootstrap and avoids advertising a teamless session.
            let tokens: (accessToken: String, refreshToken: String)
            do {
                tokens = try await auth.currentTokens()
            } catch {
                return // not signed in -> nothing to announce
            }
            guard generation == nil || lifecycleGeneration == generation else { return }
            _ = tokens.refreshToken
            accessToken = tokens.accessToken
            identity = currentIdentity
        }

        if !stopping && !signedOut {
            queueDepartureIfNeeded(beforeAnnouncing: identity)
            await flushPendingDepartures(
                accessToken: accessToken,
                generation: generation
            )
            guard generation == nil || lifecycleGeneration == generation else { return }
        }

        let succeeded = await sendHeartbeatRequest(
            stopping: stopping,
            signedOut: signedOut,
            generation: generation,
            accessToken: accessToken,
            identity: identity
        )
        guard succeeded else { return }
        // A normal beat can finish after sign-out, a team switch, or a route
        // restart. Its server request is harmless because the worker fences the
        // old lifecycle, but its local bookkeeping must not make that stale
        // identity look current and defeat the next departure flush.
        guard generation == nil || lifecycleGeneration == generation else { return }
        if signedOut {
            pendingDepartureIdentities.removeAll {
                Self.samePresenceScope($0, identity)
            }
            if let lastAnnouncedIdentity,
               Self.samePresenceScope(lastAnnouncedIdentity, identity) {
                self.lastAnnouncedIdentity = nil
            }
        } else if !stopping {
            lastAnnouncedIdentity = identity
        }
    }

    private func sendHeartbeatRequest(
        stopping: Bool,
        signedOut: Bool,
        generation: UInt64?,
        accessToken: String,
        identity: HeartbeatIdentity
    ) async -> Bool {
        guard let baseURL = Self.resolvedServiceURL() else { return false }

        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/presence/heartbeat"
        guard let url = comps.url else { return false }

        let bodyDict = Self.heartbeatBody(
            deviceID: identity.deviceID,
            tag: identity.tag,
            bundleID: identity.bundleID,
            displayName: identity.displayName,
            routes: identity.routes,
            stopping: stopping,
            signedOut: signedOut,
            lifecycleID: identity.lifecycleID
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = identity.teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict, options: [])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false // best-effort; retry happens on the next cadence tick
            }
            // Mirrors the JSONSerialization encode above; a typed Decodable
            // here would be a second major type in this file.
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverInterval = payload["heartbeatIntervalMs"] as? Int,
               serverInterval >= 1_000 {
                if generation == nil || lifecycleGeneration == generation {
                    intervalMs = serverInterval
                }
            }
            return true
        } catch {
            // best-effort; presence must never disrupt the Mac.
            return false
        }
    }

    private func queueDepartureIfNeeded(beforeAnnouncing identity: HeartbeatIdentity) {
        guard let lastAnnouncedIdentity,
              !Self.samePresenceScope(lastAnnouncedIdentity, identity),
              !pendingDepartureIdentities.contains(where: {
                  Self.samePresenceScope($0, lastAnnouncedIdentity)
              }) else { return }
        pendingDepartureIdentities.append(lastAnnouncedIdentity)
        trimPendingDepartures()
    }

    private func trimPendingDepartures() {
        if pendingDepartureIdentities.count > 8 {
            pendingDepartureIdentities.removeFirst(
                pendingDepartureIdentities.count - 8
            )
        }
    }

    private func flushPendingDepartures(
        accessToken: String,
        generation: UInt64?
    ) async {
        for identity in pendingDepartureIdentities {
            let succeeded = await sendHeartbeatRequest(
                stopping: true,
                signedOut: true,
                generation: generation,
                accessToken: accessToken,
                identity: identity
            )
            guard generation == nil || lifecycleGeneration == generation else { return }
            if succeeded {
                pendingDepartureIdentities.removeAll {
                    Self.samePresenceScope($0, identity)
                }
            }
        }
    }

    nonisolated private static func samePresenceScope(
        _ lhs: HeartbeatIdentity,
        _ rhs: HeartbeatIdentity
    ) -> Bool {
        lhs.teamID == rhs.teamID
            && lhs.deviceID == rhs.deviceID
            && lhs.tag == rhs.tag
            && lhs.lifecycleID == rhs.lifecycleID
    }

    /// Build the heartbeat JSON body. Routes are always present (the wire
    /// treats an absent field as "unchanged", but this client knows the full
    /// current set on every beat, so it always states it — an empty array
    /// accurately means "no routes", e.g. mobile pairing off). Pure and
    /// nonisolated for tests.
    nonisolated static func heartbeatBody(
        deviceID: String,
        tag: String,
        bundleID: String?,
        displayName: String?,
        routes: [CmxAttachRoute],
        stopping: Bool,
        signedOut: Bool = false,
        lifecycleID: String? = nil,
        now: Date = Date()
    ) -> [String: Any] {
        var bodyDict: [String: Any] = [
            "deviceId": deviceID,
            "platform": "mac",
            "tag": tag,
            "routes": routes.mobileHostJSONObjects(for: .cloudRendezvous, at: now),
        ]
        // The app's bundle id lets the phone label the build channel on the
        // Computers screen (com.cmuxterm.app = Stable, .nightly/.rc/.staging
        // suffixes, dev.cmux.* = a DEV build — paired with `tag` for the dev tag).
        if let bundleID, !bundleID.isEmpty {
            bodyDict["bundleId"] = bundleID
        }
        if let displayName, !displayName.isEmpty {
            bodyDict["displayName"] = displayName
        }
        if stopping {
            bodyDict["stopping"] = true
        }
        if signedOut {
            bodyDict["signedOut"] = true
        }
        if let lifecycleID, !lifecycleID.isEmpty {
            bodyDict["lifecycleId"] = lifecycleID
        }
        return bodyDict
    }

    nonisolated private static func makeLifecycleID() -> String {
        UUID().uuidString.lowercased()
    }

}
