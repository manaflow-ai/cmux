public import CMUXMobileCore
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
    ///   - deviceID: This iOS device's registry id (``MobileDeviceIdentity``).
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

    // MARK: - Parsing (pure, testable)

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
        // Instances are returned most-recently-seen first; the first instance
        // with at least one decodable route is the freshest reachable one.
        for instance in device.instances {
            let routes = instance.routes.compactMap(\.value)
            if !routes.isEmpty { return routes }
        }
        return nil
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
