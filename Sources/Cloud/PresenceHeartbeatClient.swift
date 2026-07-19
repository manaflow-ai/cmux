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

    private let session: URLSession = .shared
    private var auth: AuthCoordinator?
    private var loopTask: Task<Void, Never>?
    private var routesObserveTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
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
        guard let auth, let baseURL = Self.resolvedServiceURL() else { return }
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

        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path)
            + "/v1/presence/heartbeat"
        guard let url = comps.url else { return }

        let bodyDict = Self.heartbeatBody(
            deviceID: MobileHostIdentity.deviceID(),
            tag: MobileHostIdentity.instanceTag(),
            bundleID: Bundle.main.bundleIdentifier,
            displayName: MobileHostIdentity.instanceDisplayName(),
            routes: currentRoutes,
            stopping: stopping
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: bodyDict, options: [])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return // best-effort; retry happens on the next cadence tick
            }
            // Mirrors the JSONSerialization encode above; a typed Decodable
            // here would be a second major type in this file.
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let serverInterval = payload["heartbeatIntervalMs"] as? Int,
               serverInterval >= 1_000 {
                intervalMs = serverInterval
            }
        } catch {
            // best-effort; presence must never disrupt the Mac.
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
        stopping: Bool
    ) -> [String: Any] {
        var bodyDict: [String: Any] = [
            "deviceId": deviceID,
            "platform": "mac",
            "tag": tag,
            "routes": routes.map(\.mobileHostJSONObject),
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
        return bodyDict
    }

}
