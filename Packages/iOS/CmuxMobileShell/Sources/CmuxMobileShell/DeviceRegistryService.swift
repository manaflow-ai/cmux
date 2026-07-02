public import CMUXMobileCore
public import CmuxMobileShellModel
public import Foundation
import os

private let deviceRegistryLog = Logger(subsystem: "com.cmuxterm.app", category: "DeviceRegistry")

/// HTTP client for the team-scoped device registry (`/api/devices`).
///
/// Looks up fresher attach routes for a paired Mac on reload. P1 only needs the
/// phone to *read* the team's Macs; registering the phone itself as a `device`
/// row is deferred to the key-pinning phase (a phone row only matters once it
/// anchors a pinned key for revoke). `deviceID` is already plumbed here so that
/// phase has the persisted identity ready.
///
/// Auth mirrors ``PushRegistrationService``: native calls send
/// `Authorization: Bearer <access>` + `X-Stack-Refresh-Token: <refresh>`, plus an
/// optional `X-Cmux-Team-Id` so the server scopes to the chosen team (defaults to
/// the Stack-selected team when omitted). Tokens are supplied through injected
/// Sendable closures so this service needs no dependency on the auth package.
///
/// Every call is best-effort and failure-tolerant: a thrown/timed-out request
/// yields `nil` so reconnect falls back to locally persisted routes and pairing
/// survives the registry being down.
public actor DeviceRegistryService: DeviceRegistryRefreshing {
    /// Supplies the bearer/refresh tokens for an authenticated request, or `nil`
    /// when there is no valid session.
    public struct TokenSource: Sendable {
        public var accessToken: @Sendable () async -> String?
        public var refreshToken: @Sendable () async -> String?

        public init(
            accessToken: @escaping @Sendable () async -> String?,
            refreshToken: @escaping @Sendable () async -> String?
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }

    private let apiBaseURL: String
    private let deviceID: String
    private let tokenSource: TokenSource
    private let teamIDProvider: @Sendable () async -> String?
    private let session: URLSession
    private let requestTimeout: TimeInterval

    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL (no trailing slash).
    ///   - deviceID: This iOS device's registry id (``deviceID(defaults:)``).
    ///   - tokenSource: Supplies the Stack access/refresh tokens.
    ///   - teamIDProvider: Supplies the team id to scope to, or `nil` to let the
    ///     server use the Stack-selected team.
    ///   - session: The URLSession used for API calls.
    ///   - requestTimeout: Per-request deadline, bounding the worst-case latency
    ///     of a registry call so it never stalls the reconnect refresh.
    public init(
        apiBaseURL: String,
        deviceID: String,
        tokenSource: TokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        session: sending URLSession = .shared,
        requestTimeout: TimeInterval = 5
    ) {
        self.apiBaseURL = apiBaseURL
        self.deviceID = deviceID
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = session
        self.requestTimeout = requestTimeout
    }

    // MARK: - Device identity

    private static let deviceIDKey = "cmux.deviceRegistry.iosDeviceID"

    /// This iOS device's stable cmux identity for the device registry.
    ///
    /// A cmux-GENERATED persisted UUID (NOT `identifierForVendor`, which resets
    /// when the last cmux app is removed, and NOT a hardware fingerprint).
    /// Persisted in `UserDefaults` so it survives relaunch and reinstall, is
    /// cross-platform, and is user-renamable via its display name. Mirrors the
    /// Mac side's `MobileHostIdentity.deviceID()`. The phone sends this id when
    /// it registers itself as a device; the key-pinning phase will anchor a
    /// pinned key to it for revoke.
    /// - Parameter defaults: Persistence store (injected for tests).
    public static func deviceID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIDKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        let generated = UUID().uuidString.lowercased()
        defaults.set(generated, forKey: deviceIDKey)
        return generated
    }

    // MARK: - Reconnect route policy (pure, testable)

    /// Choose the routes to persist for the next reconnect.
    ///
    /// The reconnect path connects on `local` routes immediately (no added
    /// latency on the common case) and only *rewrites* the persisted routes when
    /// the registry returns a usable, different set, so a stale-route Mac gets
    /// rescued on the next reconnect trigger. Returns `nil` to signal "no change
    /// needed" (registry unavailable, empty, or identical), letting callers skip
    /// a redundant store write and fall back to the locally persisted routes.
    ///
    /// The registry is authoritative for HOST/PORT routes only (its fresher
    /// host/port rescues a stale local one — the original purpose of this
    /// refresh). PEER (iroh) routes are owned by attach tickets and live
    /// presence pushes, both of which carry the Mac's CURRENT EndpointId; the
    /// registry's copy is a snapshot that lags identity changes, so it never
    /// overwrites or removes a local peer route here.
    ///
    /// Both failure modes were hit in dogfood before this shape:
    /// - wholesale replacement: a Mac switched to the iroh-only cmuxRelay lane
    ///   while its registry row still held only an old tailscale host/port; the
    ///   refresh deleted the freshly-paired iroh route, and every later cold
    ///   open dialed the dead TCP port.
    /// - per-KIND authority: the registry's stale iroh route (an EndpointId the
    ///   Mac had already rotated away from) overwrote the freshly-attached
    ///   current one, so the very next cold open dialed a dead peer identity.
    public static func selectReconnectRoutes(
        local: [CmxAttachRoute],
        registry: [CmxAttachRoute]?
    ) -> [CmxAttachRoute]? {
        guard let registry, !registry.isEmpty else { return nil }
        func isHostPort(_ route: CmxAttachRoute) -> Bool {
            if case .hostPort = route.endpoint { return true }
            return false
        }
        let registryHostPort = registry.filter(isHostPort)
        let registryHostPortKinds = Set(registryHostPort.map(\.kind))
        let preservedLocal = local.filter { route in
            !isHostPort(route) || !registryHostPortKinds.contains(route.kind)
        }
        let merged = registryHostPort + preservedLocal
        guard !merged.isEmpty, merged != local else { return nil }
        return merged
    }

    /// Whether a background registry refresh may write back into the paired-Mac
    /// store, re-evaluated *after* the network call.
    ///
    /// The refresh upserts with `markActive: true`, so it must not resurrect a
    /// pairing the user removed or deactivated while the network call was in
    /// flight. It is safe to apply only when the same user is still signed in and
    /// the Mac it refreshed is still the active paired Mac. If the user signed
    /// out, switched accounts, forgot the Mac, or switched to a different active
    /// Mac, the captured user no longer matches, or the active Mac id is now
    /// `nil`/different, so the write is rejected.
    public static func shouldApplyRegistryRefresh(
        isSignedIn: Bool,
        capturedUserID: String?,
        currentUserID: String?,
        activeMacID: String?,
        targetMacID: String
    ) -> Bool {
        guard isSignedIn else { return false }
        guard capturedUserID == currentUserID else { return false }
        return activeMacID == targetMacID
    }

    // MARK: - DeviceRegistryRefreshing

    public func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]? {
        guard let request = await makeRequest(method: "GET", path: "/api/devices", body: nil) else {
            return nil
        }
        let data: Data
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            data = responseData
        } catch {
            deviceRegistryLog.debug("freshRoutes request failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return Self.routes(forMacDeviceID: macDeviceID, in: data)
    }

    public func listDevices() async -> DeviceRegistryListOutcome {
        // No request could be built (no valid session/tokens): treat as a
        // transient failure rather than an auth rejection, since this is the
        // signed-out / not-yet-bootstrapped case, not the registry actively
        // rejecting the caller's scope.
        guard let request = await makeRequest(method: "GET", path: "/api/devices", body: nil) else {
            return .transientFailure
        }
        let data: Data
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .transientFailure
            }
            // An auth/scope rejection (401/403) must clear the cached team-scoped
            // data; any other non-2xx (5xx, etc.) is transient and keeps it.
            if http.statusCode == 401 || http.statusCode == 403 {
                return .authRejected
            }
            guard (200...299).contains(http.statusCode) else {
                return .transientFailure
            }
            data = responseData
        } catch {
            deviceRegistryLog.debug("listDevices request failed: \(String(describing: error), privacy: .public)")
            return .transientFailure
        }
        // A 2xx with an undecodable body is a server/contract glitch, not an auth
        // rejection: keep the current tree rather than blanking it.
        guard let devices = Self.parseDeviceList(in: data) else {
            return .transientFailure
        }
        return .ok(devices)
    }

    // MARK: - Parsing (pure, testable)

    /// Decode the `/api/devices` list response into the full two-level device
    /// tree (devices → app instances), for the device tree UI. Returns `nil` only
    /// when the top-level envelope is undecodable; individual bad routes are
    /// dropped (not fatal) so one malformed sibling can't blank the whole tree.
    ///
    /// Each route is decoded *failably* and individually (same forward-compat
    /// contract as ``routes(forMacDeviceID:in:)``): a malformed or unknown-kind
    /// route is skipped rather than failing its instance, so an old client stays
    /// forward-compatible when a newer build advertises a route kind it cannot
    /// decode. `lastSeenAt` is parsed leniently (ISO8601, with or without
    /// fractional seconds), defaulting to ``Date/distantPast`` when absent so a
    /// device still renders, just sorted oldest.
    static func parseDeviceList(in data: Data) -> [RegistryDevice]? {
        struct FailableRoute: Decodable {
            let value: CmxAttachRoute?
            init(from decoder: Decoder) throws {
                value = try? CmxAttachRoute(from: decoder)
            }
        }
        struct Instance: Decodable {
            let tag: String?
            let routes: [FailableRoute]?
            let lastSeenAt: String?
        }
        struct Device: Decodable {
            let deviceId: String
            let platform: String?
            let displayName: String?
            let lastSeenAt: String?
            let instances: [Instance]?
        }
        struct ListResponse: Decodable {
            let devices: [Device]
        }
        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            return nil
        }
        return decoded.devices.compactMap { device -> RegistryDevice? in
            let deviceId = device.deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !deviceId.isEmpty else { return nil }
            let instances = (device.instances ?? []).map { instance in
                RegistryAppInstance(
                    tag: instance.tag?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? instance.tag! : "default",
                    routes: (instance.routes ?? []).compactMap(\.value),
                    lastSeenAt: Self.parseTimestamp(instance.lastSeenAt)
                )
            }
            return RegistryDevice(
                deviceId: deviceId,
                platform: device.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? device.platform! : "mac",
                displayName: device.displayName,
                lastSeenAt: Self.parseTimestamp(device.lastSeenAt),
                instances: instances
            )
        }
    }

    /// Lenient ISO8601 parse for the registry's `lastSeenAt` strings. The server
    /// emits `Date.toISOString()` (always fractional seconds), but tolerate the
    /// non-fractional form too. An absent/unparseable value yields
    /// ``Date/distantPast`` so the device still renders rather than being dropped.
    ///
    /// The formatters are created per call rather than cached in a `static` so
    /// this stays `Sendable`-clean under strict concurrency (`ISO8601DateFormatter`
    /// is not `Sendable`). This runs once per `/api/devices` response, not on any
    /// hot path, so the allocation is negligible.
    static func parseTimestamp(_ value: String?) -> Date {
        guard let value, !value.isEmpty else { return .distantPast }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        return .distantPast
    }

    /// Decode the `/api/devices` list response and return the routes for the
    /// device whose id matches `macDeviceID`, preferring its most recently seen
    /// app instance. Returns `nil` when the device or routes are absent so the
    /// caller falls back to local routes.
    ///
    /// Each route is decoded *failably* and individually: a malformed or
    /// unknown-kind route from any instance (even another Mac's) is skipped
    /// rather than failing the whole response. This keeps one bad sibling row
    /// from disabling registry refresh for every Mac, and makes old clients
    /// forward-compatible when a newer build advertises a route kind they cannot
    /// decode.
    static func routes(forMacDeviceID macDeviceID: String, in data: Data) -> [CmxAttachRoute]? {
        // Decode each route element through an optional wrapper so a single bad
        // element decodes to `nil` and is dropped, never throwing for the array.
        struct FailableRoute: Decodable {
            let value: CmxAttachRoute?
            init(from decoder: Decoder) throws {
                value = try? CmxAttachRoute(from: decoder)
            }
        }
        struct Instance: Decodable {
            let routes: [FailableRoute]
        }
        struct Device: Decodable {
            let deviceId: String
            let instances: [Instance]
        }
        struct ListResponse: Decodable {
            let devices: [Device]
        }
        guard let decoded = try? JSONDecoder().decode(ListResponse.self, from: data) else {
            return nil
        }
        let target = macDeviceID.lowercased()
        guard let device = decoded.devices.first(where: { $0.deviceId.lowercased() == target }) else {
            return nil
        }
        // A Mac may run multiple tagged app instances (stable + a debug build).
        // The phone's stored routes have no tag to match against in P1, so only
        // substitute routes when exactly one instance is advertising any (the
        // single-build common case). With zero or 2+ candidate instances, return
        // nil and let reconnect fall back to the locally persisted routes, rather
        // than risk connecting a stable phone to a different tagged build's
        // workspaces. Tag-aware matching is a follow-up (see key-pinning phase).
        let nonEmpty = device.instances
            .map { $0.routes.compactMap(\.value) }
            .filter { !$0.isEmpty }
        return nonEmpty.count == 1 ? nonEmpty[0] : nil
    }

    // MARK: - Request building

    private func makeRequest(method: String, path: String, body: [String: Any]?) async -> URLRequest? {
        guard let accessToken = await tokenSource.accessToken(),
              let refreshToken = await tokenSource.refreshToken(),
              let url = URL(string: apiBaseURL + path) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID = await teamIDProvider(), !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
