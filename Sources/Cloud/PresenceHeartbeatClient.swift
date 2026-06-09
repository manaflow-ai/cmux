import CmuxAuthRuntime
import Foundation

/// UserDefaults keys for the device presence heartbeat. Default OFF: the Mac
/// announces nothing unless the flag is enabled and a service URL is set.
enum PresenceSettings {
    /// Master gate. When false (default), no heartbeats are sent.
    static let enabledKey = "presenceHeartbeatEnabled"
    /// Base URL of the presence service (the cmux-presence worker), e.g.
    /// "https://cmux-presence.<account>.workers.dev". Empty means disabled.
    static let serviceURLKey = "presenceServiceURL"
    /// Env override for dev/tagged builds, mirroring CMUX_VM_API_BASE_URL.
    static let serviceURLEnvKey = "CMUX_PRESENCE_BASE_URL"
}

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
/// Offline is explicit on the server: a clean quit sends a `stopping: true`
/// goodbye; a crash or sleep is caught by the service's missed-heartbeat alarm
/// (45s), so this client never needs a watchdog of its own.
@MainActor
final class PresenceHeartbeatClient {
    static let shared = PresenceHeartbeatClient()

    private let session: URLSession = .shared
    private var auth: AuthCoordinator?
    private var loopTask: Task<Void, Never>?
    private var defaultsObserver: NSObjectProtocol?
    /// Cadence between heartbeats; server-owned, seeded with the service default.
    private var intervalMs: Int = 15_000

    private init() {}

    /// Inject the auth dependency and start (or arm) the heartbeat loop. Call
    /// once at the composition root, alongside ``DeviceRegistryClient``.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
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

    // MARK: - Loop lifecycle

    private var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: PresenceSettings.enabledKey)
    }

    /// Resolved service base URL: env override first (dev/tagged builds), then
    /// the defaults key. Nil disables the client entirely.
    static func resolvedServiceURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) -> URL? {
        let raw = environment[PresenceSettings.serviceURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? defaults.string(forKey: PresenceSettings.serviceURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private struct HeartbeatResponse: Decodable {
        var heartbeatIntervalMs: Int?
    }

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

        var bodyDict: [String: Any] = [
            "deviceId": MobileHostIdentity.deviceID(),
            "platform": "mac",
            "tag": Self.buildTag(),
        ]
        if let displayName = MobileHostIdentity.displayName(), !displayName.isEmpty {
            bodyDict["displayName"] = displayName
        }
        if stopping {
            bodyDict["stopping"] = true
        }

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
            if let decoded = try? JSONDecoder().decode(HeartbeatResponse.self, from: data),
               let serverInterval = decoded.heartbeatIntervalMs,
               serverInterval >= 1_000 {
                intervalMs = serverInterval
            }
        } catch {
            // best-effort; presence must never disrupt the Mac.
        }
    }

    /// The build tag for this cmux instance, matching the registry's instance
    /// key so presence rows line up with `device_app_instances.tag`.
    private static func buildTag() -> String {
        let tag = ProcessInfo.processInfo.environment["CMUX_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (tag?.isEmpty == false) ? tag! : "default"
    }
}
