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
/// (45s), so this client never needs a watchdog of its own. Sign-out is
/// stronger than offline: a `stopping + signout` goodbye tells the service to
/// REMOVE the instance from the team (the account left this Mac), sent once
/// per team beaten this session via
/// ``goodbyeForSignOut(accessToken:refreshToken:)`` and on mid-session team
/// switches. Auth transitions are observed live, so a sign-in beats
/// immediately instead of waiting out the cadence.
@MainActor
final class PresenceHeartbeatClient {
    static let shared = PresenceHeartbeatClient()

    private let session: URLSession = .shared
    private var auth: AuthCoordinator?
    private var loopTask: Task<Void, Never>?
    private var routesObserveTask: Task<Void, Never>?
    private let authObserver = CloudAuthStateObserver()
    private var authObserveTask: Task<Void, Never>?
    /// The last auth scope the observer yielded; `nil` until the first yield,
    /// which is treated as a baseline (the loop owns steady-state beats).
    private var lastAuthState: CloudAuthObservedState?
    private var defaultsObserver: NSObjectProtocol?
    /// Cadence between heartbeats; server-owned, seeded with the service default.
    private var intervalMs: Int = 15_000
    /// The attach routes most recently advertised by ``MobileHostService``,
    /// included in every heartbeat so the presence service mirrors the same
    /// set the device registry stores (DO = live cache, registry = truth).
    private var currentRoutes: [CmxAttachRoute] = []
    /// Team markers (``DeviceRegistryClient/teamMarker(_:)`` encoding) whose
    /// heartbeats succeeded this session. In-memory only: presence self-heals
    /// through the 45s missed-heartbeat alarm, so a crash losing this set only
    /// delays the offline flip, never leaks a row. Sign-out and team switches
    /// send the stronger `signout` goodbye to exactly these teams.
    private var beatenTeamMarkers: Set<String> = []

    private init() {}

    /// Inject the auth dependency and start (or arm) the heartbeat loop. Call
    /// once at the composition root, alongside ``DeviceRegistryClient``.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        startObservingRoutes()
        startObservingAuth()
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
        evaluate()
    }

    /// Cancel the loop and send a best-effort goodbye. Called from
    /// `applicationWillTerminate`; the process may exit before the request
    /// lands, which is fine: the service's missed-heartbeat timeout covers
    /// every unclean path, the goodbye only makes clean quits flip offline
    /// immediately instead of within 45s.
    func appWillTerminate() {
        guard loopTask != nil else { return }
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
                    await self.sendHeartbeat(stopping: false)
                }
            }
        }
    }

    // MARK: - Auth transitions

    /// React to auth transitions between cadence ticks: a sign-in beats
    /// immediately (and arms the loop) so the phone sees the Mac online within
    /// a round trip; a mid-session team switch says a `signout` goodbye to the
    /// team being left (its list must drop this Mac, not just show it
    /// offline), then beats into the new team. A sign-out observed here sends
    /// nothing: the live token store is already empty, and the flow hooks /
    /// coordinator backstop deliver the captured pair to
    /// ``goodbyeForSignOut(accessToken:refreshToken:)`` instead.
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
            // Fresh session: arm the loop if the gate allows it. A freshly
            // started loop beats immediately on its first iteration; an
            // already-running one gets one out-of-cadence beat.
            let loopWasRunning = loopTask != nil
            evaluate()
            if loopWasRunning {
                await sendHeartbeat(stopping: false)
            }
        } else if state.isAuthenticated, previous.isAuthenticated, previous.teamID != state.teamID {
            await moveHeartbeat(from: previous.teamID)
        }
    }

    /// Mid-session team switch: `signout`-goodbye the team being left with the
    /// still-valid current tokens, then beat into the new team immediately.
    private func moveHeartbeat(from oldTeamID: String?) async {
        let oldMarker = DeviceRegistryClient.teamMarker(oldTeamID)
        if beatenTeamMarkers.contains(oldMarker),
           let auth,
           let tokens = try? await auth.currentTokens() {
            _ = await postHeartbeat(
                accessToken: tokens.accessToken,
                teamMarker: oldMarker,
                stopping: true,
                signout: true
            )
            beatenTeamMarkers.remove(oldMarker)
        }
        await sendHeartbeat(stopping: false)
    }

    // MARK: - Sign-out goodbye

    /// Announce this instance's sign-out to every team beaten this session,
    /// with the pre-clear token pair captured by the sign-out flow (or the
    /// coordinator's invalidation backstop); the live token store is already
    /// empty when this runs. `stopping + signout` makes the presence service
    /// REMOVE the instance rather than flip it offline, so phones drop this
    /// Mac from their lists live. Best-effort and never throws; a miss
    /// self-heals through the 45s alarm (offline, and the registry
    /// deregistration already removed the durable row). The refresh token is
    /// accepted for signature parity with the registry teardown but unused:
    /// the presence worker authenticates on the bearer token alone.
    func goodbyeForSignOut(accessToken: String?, refreshToken: String?) async {
        _ = refreshToken
        let markers = beatenTeamMarkers
        // The session is over either way; a new sign-in repopulates the set
        // from its own successful beats.
        beatenTeamMarkers.removeAll()
        guard let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return
        }
        for marker in markers {
            _ = await postHeartbeat(
                accessToken: accessToken,
                teamMarker: marker,
                stopping: true,
                signout: true
            )
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
        let shouldRun = auth != nil && isEnabled && Self.resolvedServiceURL() != nil
        if shouldRun && loopTask == nil {
            startLoop()
        } else if !shouldRun, loopTask != nil {
            stopLoop()
            // Flag turned off while running: announce the disappearance instead
            // of leaving the instance to time out.
            Task { await self.sendHeartbeat(stopping: true) }
        }
    }

    private func startLoop() {
        loopTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                guard let self else { return }
                await self.sendHeartbeat(stopping: false)
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

    // MARK: - Heartbeat

    private func sendHeartbeat(stopping: Bool) async {
        guard let auth else { return }
        // Await tokens first, mirroring DeviceRegistryClient: gates on "signed
        // in" and on launch auth bootstrap so the team header resolves from a
        // populated team list rather than the Stack default.
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return // not signed in -> nothing to announce
        }
        let teamID = auth.resolvedTeamID
        let succeeded = await postHeartbeat(
            accessToken: tokens.accessToken,
            teamMarker: DeviceRegistryClient.teamMarker(teamID),
            stopping: stopping,
            signout: false
        )
        if succeeded, !stopping {
            // Only teams that actually heard a beat need a sign-out goodbye.
            beatenTeamMarkers.insert(DeviceRegistryClient.teamMarker(teamID))
        }
    }

    /// One heartbeat POST against one explicit team scope, shared by the
    /// cadence loop, the team-switch goodbye, and the sign-out goodbye (which
    /// present captured tokens the live store no longer holds). An empty
    /// marker means "no `X-Cmux-Team-Id` header": the service resolves the
    /// caller's default team, matching the beat that created the record.
    @discardableResult
    private func postHeartbeat(
        accessToken: String,
        teamMarker: String,
        stopping: Bool,
        signout: Bool
    ) async -> Bool {
        guard let baseURL = Self.resolvedServiceURL() else { return false }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return false }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/presence/heartbeat"
        guard let url = comps.url else { return false }

        let bodyDict = Self.heartbeatBody(
            deviceID: MobileHostIdentity.deviceID(),
            tag: MobileHostIdentity.instanceTag(),
            bundleID: Bundle.main.bundleIdentifier,
            displayName: MobileHostIdentity.instanceDisplayName(),
            routes: currentRoutes,
            stopping: stopping,
            signout: signout
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // Goodbyes ride sign-out's bounded teardown window; keep every beat
        // short so a hung service can't eat that budget (a missed beat just
        // waits for the next cadence tick).
        req.timeoutInterval = signout ? 4 : 10
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if !teamMarker.isEmpty {
            req.setValue(teamMarker, forHTTPHeaderField: "X-Cmux-Team-Id")
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
                intervalMs = serverInterval
            }
            return true
        } catch {
            // best-effort; presence must never disrupt the Mac.
            return false
        }
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
        signout: Bool = false,
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
            // Signout is only meaningful on a goodbye: it upgrades "this
            // instance went offline" to "this instance left the account,
            // remove it from the team's list". Never emitted without
            // `stopping`, so old workers that ignore the unknown field
            // degrade to a plain goodbye.
            if signout {
                bodyDict["signout"] = true
            }
        }
        return bodyDict
    }

}
