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
    private let session: CmxCredentialedHTTPSession
    private let requestTimeout: TimeInterval

    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL (no trailing slash).
    ///   - deviceID: This iOS device's registry id (``deviceID(defaults:)``).
    ///   - tokenSource: Supplies the Stack access/refresh tokens.
    ///   - teamIDProvider: Supplies the team id to scope to, or `nil` to let the
    ///     server use the Stack-selected team.
    ///   - sessionConfiguration: URL loading configuration. Redirect rejection,
    ///     cookie isolation, and cache isolation are enforced by the service.
    ///   - requestTimeout: Per-request deadline, bounding the worst-case latency
    ///     of a registry call so it never stalls the reconnect refresh.
    public init(
        apiBaseURL: String,
        deviceID: String,
        tokenSource: TokenSource,
        teamIDProvider: @escaping @Sendable () async -> String? = { nil },
        sessionConfiguration: sending URLSessionConfiguration = .ephemeral,
        requestTimeout: TimeInterval = 5
    ) {
        self.apiBaseURL = apiBaseURL
        self.deviceID = deviceID
        self.tokenSource = tokenSource
        self.teamIDProvider = teamIDProvider
        self.session = CmxCredentialedHTTPSession(configuration: sessionConfiguration)
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
    /// latency on the common case) and only *replaces* the persisted routes when
    /// the registry returns a usable, different set, so a stale-route Mac gets
    /// rescued on the next reconnect trigger. Returns `nil` to signal "no change
    /// needed" (registry unavailable, empty, or identical), letting callers skip
    /// a redundant store write and fall back to the locally persisted routes.
    public static func selectReconnectRoutes(
        local: [CmxAttachRoute],
        registry: [CmxAttachRoute]?
    ) -> [CmxAttachRoute]? {
        guard let registry, !registry.isEmpty else { return nil }
        guard registry != local else { return nil }
        return registry
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
        activeMacInstanceTag: String? = nil,
        targetMacID: String,
        targetInstanceTag: String? = nil
    ) -> Bool {
        guard isSignedIn else { return false }
        guard capturedUserID == currentUserID else { return false }
        return activeMacID == targetMacID && activeMacInstanceTag == targetInstanceTag
    }

    // MARK: - DeviceRegistryRefreshing

    public func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]? {
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
        return Self.routes(
            forMacDeviceID: macDeviceID,
            pairedMacInstanceTag: instanceTag,
            in: data
        )
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
                let tag = instance.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
                return RegistryAppInstance(
                    tag: tag?.isEmpty == false ? tag! : "default",
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

    /// Return authoritative routes for a matching device from one decoded
    /// registry snapshot. A scoped client selects its exact Mac app-instance
    /// tag; an unscoped client accepts routes only when exactly one instance on
    /// that physical device advertises any. Returns `nil` when ownership cannot
    /// be proven.
    static func routes(
        forMacDeviceID macDeviceID: String,
        pairedMacInstanceTag: String? = nil,
        in devices: [RegistryDevice]
    ) -> [CmxAttachRoute]? {
        guard case .unique(let routes) = DeviceRegistryRouteIndex(devices: devices).resolve(
            macDeviceID: macDeviceID,
            instanceTag: pairedMacInstanceTag
        ) else { return nil }
        return routes
    }

    /// Decode the `/api/devices` list response and return authoritative routes
    /// for the matching device. Each route is decoded *failably* and
    /// individually by ``parseDeviceList(in:)``: a malformed or unknown-kind
    /// route from any instance is skipped rather than failing the whole response.
    /// This keeps one bad sibling row from disabling registry refresh for every
    /// Mac and makes old clients forward-compatible with new route kinds.
    static func routes(
        forMacDeviceID macDeviceID: String,
        pairedMacInstanceTag: String? = nil,
        in data: Data
    ) -> [CmxAttachRoute]? {
        guard let devices = parseDeviceList(in: data) else { return nil }
        return routes(
            forMacDeviceID: macDeviceID,
            pairedMacInstanceTag: pairedMacInstanceTag,
            in: devices
        )
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

/// Exact, immutable authority lookup for one authenticated registry generation.
/// Building it once keeps a reconnect pass linear even with many saved Macs.
struct DeviceRegistryRouteIndex: Sendable {
    private let devicesByID: [String: [RegistryDevice]]

    init(devices: [RegistryDevice]) {
        devicesByID = Dictionary(grouping: devices) { device in
            Self.normalizedDeviceID(device.deviceId)
        }
    }

    func resolve(
        macDeviceID: String,
        instanceTag: String?
    ) -> DeviceRegistryRouteResolution {
        let matches = devicesByID[Self.normalizedDeviceID(macDeviceID)] ?? []
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1, let device = matches.first else { return .ambiguous }

        let instances: [RegistryAppInstance]
        if let expectedTag = MobileMacInstanceTagAuthority.normalized(instanceTag) {
            instances = device.instances.filter {
                MobileMacInstanceTagAuthority.normalized($0.tag) == expectedTag
            }
        } else {
            instances = device.instances
        }
        let nonEmptyRoutes = instances.map(\.routes).filter { !$0.isEmpty }
        guard !nonEmptyRoutes.isEmpty else { return .missing }
        guard nonEmptyRoutes.count == 1 else { return .ambiguous }
        return .unique(nonEmptyRoutes[0])
    }

    private static func normalizedDeviceID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum DeviceRegistryRouteResolution: Equatable, Sendable {
    case unique([CmxAttachRoute])
    case missing
    case ambiguous
}
