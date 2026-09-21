import CMUXMobileCore
import CmuxAuthRuntime
import Foundation

/// Reads the team's durable device registry (`GET /api/devices`), the source
/// of record for devices that presence no longer remembers (an offline Mac
/// stays listed with its last known name). The registry is a rendezvous layer:
/// unreachable means "keep what we have", never "the account has no devices".
///
/// `RemotesClient` reads the same endpoint but flattens each device to its
/// newest instance and filters to manual remotes; the Devices tab needs every
/// tagged instance, so this client decodes the full two-level shape.
actor DeviceRegistryDirectoryClient {
    struct Instance: Equatable, Sendable {
        let tag: String
        let routes: [CmxAttachRoute]
        let lastSeenAt: Date?
    }

    struct Device: Equatable, Sendable {
        let deviceID: String
        let platform: String
        let displayName: String?
        /// `labels.manual == true`: a remote the person added by hand with
        /// `cmux remotes add`, not a Mac running cmux.
        let isManual: Bool
        let lastSeenAt: Date?
        let instances: [Instance]
    }

    enum ListError: Error, Equatable {
        case notSignedIn
        case httpStatus(Int)
        case malformedResponse
    }

    /// The account-bound session provider: it throws once the signed-in
    /// account or team scope is no longer the one this client was created
    /// for, so a request never carries a later account's tokens.
    typealias SessionProvider = @Sendable () async throws -> AuthenticatedSessionSnapshot

    private let sessionProvider: SessionProvider
    private let teamID: String?
    private let baseURL: URL
    private let session = CmxCredentialedHTTPSession()

    init(
        session: @escaping SessionProvider,
        teamID: String?,
        baseURL: URL = AuthEnvironment.deviceRegistryAPIBaseURL
    ) {
        sessionProvider = session
        self.teamID = teamID
        self.baseURL = baseURL
    }

    func list() async throws -> [Device] {
        let tokens: AuthenticatedSessionSnapshot
        do {
            tokens = try await sessionProvider()
        } catch HiveAccountTokenSource.Failure.accountChanged {
            throw ListError.notSignedIn
        }
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ListError.malformedResponse
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/api/devices"
        guard let url = comps.url else { throw ListError.malformedResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ListError.malformedResponse }
        guard (200...299).contains(http.statusCode) else { throw ListError.httpStatus(http.statusCode) }
        guard let devices = Self.parse(data) else { throw ListError.malformedResponse }
        return devices
    }

    /// Decode the list response. Routes decode per entry so one unknown route
    /// kind never drops a device; timestamps parse leniently (ISO8601 with or
    /// without fractional seconds). Pure for tests.
    static func parse(_ data: Data) -> [Device]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawDevices = object["devices"] as? [[String: Any]] else {
            return nil
        }
        return rawDevices.compactMap { raw -> Device? in
            guard let deviceID = (raw["deviceId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !deviceID.isEmpty else { return nil }
            let labels = raw["labels"] as? [String: Any]
            let instances = ((raw["instances"] as? [[String: Any]]) ?? []).map { instance -> Instance in
                let tag = (instance["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return Instance(
                    tag: tag.isEmpty ? SurfaceDeviceInstanceID.defaultTag : tag,
                    routes: parseRoutes(instance["routes"]),
                    lastSeenAt: parseTimestamp(instance["lastSeenAt"] as? String)
                )
            }
            return Device(
                deviceID: deviceID,
                platform: ((raw["platform"] as? String)?.lowercased()).flatMap { $0.isEmpty ? nil : $0 } ?? "mac",
                displayName: (raw["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                isManual: (labels?["manual"] as? Bool) ?? false,
                lastSeenAt: parseTimestamp(raw["lastSeenAt"] as? String),
                instances: instances
            )
        }
    }

    static func parseRoutes(_ raw: Any?) -> [CmxAttachRoute] {
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let data = try? JSONSerialization.data(withJSONObject: entry) else { return nil }
            return try? JSONDecoder().decode(CmxAttachRoute.self, from: data)
        }
    }

    static func parseTimestamp(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
