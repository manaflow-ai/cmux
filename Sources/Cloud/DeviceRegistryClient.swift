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
    /// The scope (team + tag + routes) most recently registered, used to skip
    /// redundant POSTs. Keyed on the full scope rather than routes alone so an
    /// account/team switch with unchanged routes still re-registers in the newly
    /// selected team instead of being deduped away.
    private var lastRegistration: Registration?

    /// The identity of a registration POST, for deduplication.
    struct Registration: Equatable {
        var teamID: String?
        var tag: String
        var routes: [CmxAttachRoute]
    }

    private init() {}

    /// Inject the auth dependency and begin observing host-route changes. Call
    /// once at the composition root (after `auth` is constructed).
    func configure(auth: AuthCoordinator) {
        self.auth = auth
        startObserving()
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
        let baseline = previous ?? Registration(teamID: current.teamID, tag: current.tag, routes: [])
        return baseline != current
    }

    private func startObserving() {
        observeTask?.cancel()
        // Registration is currently driven only by host-route changes. The dedup
        // key includes the team, so a team switch *does* re-register once the
        // next status tick arrives, but a mid-session team switch with otherwise
        // unchanged routes is not registered in the new team until then. Known
        // limitation; an explicit auth/team-change trigger is a follow-up.
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                await self?.registerIfRoutesChanged(routes: status.routes)
            }
        }
    }

    private func registerIfRoutesChanged(routes: [CmxAttachRoute]) async {
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
        let registration = Registration(teamID: teamID, tag: tag, routes: routes)
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
            "routes": routes.map(\.mobileHostJSONObject),
        ]
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
