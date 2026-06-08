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
    private var auth: AuthCoordinator?
    private var observeTask: Task<Void, Never>?
    /// The route set most recently registered, used to skip redundant POSTs when
    /// `statusUpdates()` fires for a connection change rather than a route change.
    private var lastRegisteredRoutes: [CmxAttachRoute]?

    private init() {}

    /// Inject the auth dependency and begin observing host-route changes. Call
    /// once at the composition root (after `auth` is constructed).
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        startObserving()
    }

    /// Whether the current advertised routes differ from what was last registered.
    ///
    /// Pure so it is unit-testable without any network or host service.
    ///
    /// Fires (returns `true`) only when the advertised routes differ from the
    /// last registration. That includes the nonempty -> empty transition (the
    /// user turned mobile pairing off): publishing the now-empty route set once
    /// clears the stale routes from the registry, and the phone already skips
    /// empty-route instances. It does NOT fire for an unchanged set (a
    /// connection-only `statusUpdates()` tick) or for the empty -> still-empty
    /// case (`nil`/`[]` start with pairing off), so the off-state is published
    /// exactly once rather than on every empty tick.
    static func shouldReRegister(
        previous: [CmxAttachRoute]?,
        current: [CmxAttachRoute]
    ) -> Bool {
        // Treat "never registered" as an empty baseline so an initial empty set
        // (pairing off at launch) is a no-op, but a later clear still fires once.
        let baseline = previous ?? []
        return baseline != current
    }

    private func startObserving() {
        observeTask?.cancel()
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                await self?.registerIfRoutesChanged(routes: status.routes)
            }
        }
    }

    private func registerIfRoutesChanged(routes: [CmxAttachRoute]) async {
        guard Self.shouldReRegister(previous: lastRegisteredRoutes, current: routes) else { return }
        guard let auth else { return }
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch {
            return // not signed in → nothing to do
        }
        let teamID = auth.resolvedTeamID

        guard var comps = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            return
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/devices"
        guard let url = comps.url else { return }

        var bodyDict: [String: Any] = [
            "deviceId": MobileHostIdentity.deviceID(),
            "platform": "mac",
            "tag": Self.buildTag(),
            "routes": routes.map(\.mobileHostJSONObject),
        ]
        if let displayName = MobileHostIdentity.displayName(), !displayName.isEmpty {
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
                    // Only remember the routes once the server accepted them, so a
                    // transient failure retries on the next status tick.
                    lastRegisteredRoutes = routes
                } else {
                    NSLog("cmux.deviceRegistry register failed status=%d", http.statusCode)
                }
            }
        } catch {
            // best-effort; registry must never disrupt the Mac.
        }
    }

    /// The build tag for this cmux instance, distinguishing dev/tagged builds
    /// from stable. Defaults to "default" so untagged stable builds register
    /// under a stable instance key.
    private static func buildTag() -> String {
        let tag = ProcessInfo.processInfo.environment["CMUX_TAG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (tag?.isEmpty == false) ? tag! : "default"
    }
}
