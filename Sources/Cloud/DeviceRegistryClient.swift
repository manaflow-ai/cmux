import CMUXMobileCore
import CmuxAuthRuntime
import CmuxIrohTransport
import Foundation

/// Registers this Mac (and its running cmux app instance's attach routes) in the
/// team-scoped device registry (`POST /api/devices`), so a phone can look up the
/// Mac's current routes on reload and auto-pair instead of re-scanning a QR.
///
/// Event-driven: it observes ``MobileHostService/statusUpdates()`` and registers
/// whenever the advertised route set changes (e.g. the Mac moved networks or
/// rebound to a different port), which is exactly the freshness the phone needs.
/// The explicit iOS pairing setting gates both route publication and the
/// registry request, so a stale status callback cannot re-register a disabled
/// Mac.
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
    private var defaultsObserver: NSObjectProtocol?
    private var teamScopeObserver: NSObjectProtocol?
    private var latestRoutes: [CmxAttachRoute] = []
    /// The scope (team + tag + routes) most recently registered, used to skip
    /// redundant POSTs. Keyed on the full scope rather than routes alone so an
    /// account/team switch with unchanged routes still re-registers in the newly
    /// selected team instead of being deduped away.
    private var lastRegistration: Registration?

    /// Consecutive failed registration attempts, reset by the first success.
    private var consecutiveFailures = 0

    /// The earliest time another registration attempt may be made.
    private var retryNotBefore: Date?

    /// Registration retries are event-driven, so a failed request does not turn
    /// every status tick into another request. Retry-After remains an upper
    /// authority when the server asks for a longer floor.
    static let retrySchedule = CmxIrohRetrySchedule(initialDelay: 5, maximumDelay: 600)

    /// Parse only bounded delta-seconds; HTTP-date values and absurd floors are
    /// ignored so malformed headers cannot silence registration indefinitely.
    nonisolated static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0, seconds <= 24 * 60 * 60 else { return nil }
        return seconds
    }

    private func holdOffAfterFailure(retryAfterSeconds: Int?) {
        consecutiveFailures += 1
        let delay = Self.retrySchedule.delay(
            failureCount: consecutiveFailures - 1,
            retryAfterSeconds: retryAfterSeconds,
            jitterUnitInterval: Double.random(in: 0...1)
        )
        retryNotBefore = Date().addingTimeInterval(delay)
    }

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
        if defaultsObserver == nil {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: UserDefaults.standard,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.evaluate()
                }
            }
        }
        if teamScopeObserver == nil {
            teamScopeObserver = NotificationCenter.default.addObserver(
                forName: .cmuxCloudTeamScopeDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.lastRegistration = nil
                    let routes = self.latestRoutes
                    Task { await self.registerIfRoutesChanged(routes: routes) }
                }
            }
        }
        evaluate()
    }

    /// Whether a registration with `current` scope differs from what was last
    /// registered, and therefore should be POSTed.
    ///
    /// Pure so it is unit-testable without any network or host service.
    ///
    /// Fires (returns `true`) when the team, tag, or routes differ from the last
    /// registration. The team is part of the key so an account/team switch with
    /// unchanged routes still registers in the new team. An unchanged scope (a
    /// connection-only `statusUpdates()` tick) and the never-registered empty
    /// start (`nil` previous with empty routes) are both no-ops. Pairing opt-out
    /// cancels observation before registering a clearing POST; the registry's
    /// missed-heartbeat/expiry path handles any stale server projection without
    /// making a backend request while iOS pairing is off.
    nonisolated static func shouldReRegister(
        previous: Registration?,
        current: Registration
    ) -> Bool {
        // Treat "never registered" as an empty-routes baseline in the same scope
        // so an initial empty set is a no-op, but a later clear while pairing
        // remains enabled, or any team/tag change, still fires.
        let baseline = previous ?? Registration(teamID: current.teamID, tag: current.tag, routes: [])
        return baseline != current
    }

    private func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { @MainActor [weak self] in
            for await status in MobileHostService.shared.statusUpdates() {
                if Task.isCancelled { break }
                self?.latestRoutes = status.routes
                await self?.registerIfRoutesChanged(routes: status.routes)
            }
        }
    }

    private func evaluate() {
        guard MobileHostService.isListeningEnabled else {
            observeTask?.cancel()
            observeTask = nil
            lastRegistration = nil
            consecutiveFailures = 0
            retryNotBefore = nil
            return
        }
        startObserving()
    }

    private func registerIfRoutesChanged(routes: [CmxAttachRoute]) async {
        // Status, route, and foreground events share this gate. Cached routes
        // remain valid while the server owns the next registration attempt.
        guard MobileHostService.isListeningEnabled else {
            // Forget the last accepted scope while pairing is off. Re-enabling
            // must POST even when the endpoint identity and routes are reused.
            lastRegistration = nil
            consecutiveFailures = 0
            retryNotBefore = nil
            return
        }
        guard await retryAfterGate.remainingSeconds() == nil else { return }
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
        guard MobileHostService.isListeningEnabled else {
            lastRegistration = nil
            return
        }
        // Resolve the team AFTER bootstrap, and use that same scope for both the
        // dedup decision and the request header, so a team switch with unchanged
        // routes is detected and the POST targets the intended team.
        let teamID = auth.resolvedTeamID
        let tag = MobileHostIdentity.instanceTag()
        let registration = Registration(teamID: teamID, tag: tag, routes: routes)
        guard Self.shouldReRegister(previous: lastRegistration, current: registration) else { return }
        if let retryNotBefore, Date() < retryNotBefore { return }

        guard var comps = URLComponents(
            url: AuthEnvironment.deviceRegistryAPIBaseURL, resolvingAgainstBaseURL: false
        ) else {
            return
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/devices"
        guard let url = comps.url else { return }

        let disclosureDate = Date()
        var bodyDict: [String: Any] = [
            "deviceId": MobileHostIdentity.deviceID(),
            "platform": "mac",
            "tag": tag,
            "routes": routes.mobileHostJSONObjects(
                for: .cloudRendezvous,
                at: disclosureDate
            ),
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
                    consecutiveFailures = 0
                    retryNotBefore = nil
                } else {
                    if http.statusCode == 429 {
                        let seconds = CmxRetryAfterPolicy.seconds(
                            from: http,
                            defaultSeconds: CmxRetryAfterPolicy.defaultRateLimitSeconds
                        ) ?? CmxRetryAfterPolicy.defaultRateLimitSeconds
                        await retryAfterGate.extend(by: seconds)
                    }
                    NSLog("cmux.deviceRegistry register failed status=%d", http.statusCode)
                    holdOffAfterFailure(retryAfterSeconds: Self.retryAfterSeconds(http))
                }
            }
        } catch {
            // Best-effort; the registry must never disrupt the Mac. Still log:
            // a silently unreachable registry strands every paired phone on
            // stale routes with nothing to diagnose from.
            NSLog("cmux.deviceRegistry register unreachable: %@", String(describing: error))
            holdOffAfterFailure(retryAfterSeconds: nil)
        }
    }

}
