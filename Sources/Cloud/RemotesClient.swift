import CMUXMobileCore
import CmuxAuthRuntime
import CryptoKit
import Foundation

/// Errors surfaced by the `cmux remotes` flow. `CustomStringConvertible` so the
/// CLI can print a clear, actionable line for each failure mode.
enum RemotesClientError: Error, CustomStringConvertible, Equatable {
    case notSignedIn
    case sessionRefreshFailed
    case invalidRoute(String)
    case loopbackRoute(host: String)
    case notAttachable(host: String)
    case noRoutes
    case emptyName
    case notFound(String)
    case httpStatus(Int, String)
    case malformedResponse(String)
    case backendUnreachable(url: String, detail: String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `cmux auth login`, then retry."
        case .sessionRefreshFailed:
            return "Signed in, but cmux could not refresh your session (network or server issue). Retry in a moment."
        case let .invalidRoute(value):
            return "Invalid route '\(value)'. Use host:port, e.g. 100.64.1.2:51001 or my-mac.tailnet.ts.net:51001."
        case let .loopbackRoute(host):
            return """
                Refusing to add a loopback remote (\(host)). A phone that dials localhost / 127.0.0.1 / ::1 dials \
                itself, so the remote would never be reachable. Use the Mac's Tailscale address instead.
                """
        case let .notAttachable(host):
            return """
                '\(host)' is not attachable from the iOS app. A signed-in phone can only authenticate to a \
                registry route over Tailscale, so the host must be a Tailscale address: a 100.64.x.x-100.127.x.x \
                (CGNAT) IP or a *.ts.net MagicDNS name. A plain LAN IP, hostname, or Tailscale IPv6 address would \
                show in the device list but fail to connect. Run `tailscale ip -4` on the Mac for its 100.x address.
                """
        case .noRoutes:
            return "At least one --route host:port is required. Example: cmux remotes add my-mac --route 100.64.1.2:51001"
        case .emptyName:
            return "A non-empty remote name is required. Example: cmux remotes add my-mac --route 100.64.1.2:51001"
        case let .notFound(target):
            return "No remote matching '\(target)'. Run `cmux remotes list` to see registered remotes."
        case let .httpStatus(status, body):
            return RemotesClient.formatHTTPError(status: status, body: body)
        case let .malformedResponse(message):
            return "The device registry returned an unexpected response: \(message)"
        case let .backendUnreachable(url, detail):
            return "Could not reach the cmux backend at \(url): \(detail)"
        }
    }
}


/// Manages user-initiated remotes in the team-scoped device registry
/// (`/api/devices`). Mirrors ``VMClient``: an actor with an injected
/// ``AuthCoordinator`` and ``URLSession`` that attaches the Stack bearer +
/// refresh + team headers to every request. This is the single registry
/// mutation path behind the `remotes.list/add/remove` socket methods and the
/// `cmux remotes` CLI verb.
actor RemotesClient {
    @MainActor private(set) static var shared: RemotesClient!

    @MainActor
    static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        shared = RemotesClient(session: session, auth: auth)
    }

    /// Namespace for deriving a stable device UUID from a remote name, so
    /// `remotes add <name>` is idempotent: re-adding the same name updates the
    /// same device row instead of creating a duplicate. A fixed v4 UUID used as
    /// a v5 namespace.
    private static let remoteNamespace = UUID(uuidString: "6f1d3c9a-2b7e-4f1a-9c0d-1a2b3c4d5e6f")!

    private let session: URLSession
    private let auth: AuthCoordinator

    init(session: URLSession = .shared, auth: AuthCoordinator) {
        self.session = session
        self.auth = auth
    }

    // MARK: - Public operations

    /// List the caller's team's MANUAL remotes (those added via
    /// `cmux remotes add`), flattened to one row per device for display.
    /// Self-registered Macs are excluded so this command never lists or removes
    /// a device the user did not add through the CLI.
    func list() async throws -> [RemoteSummary] {
        try await allDevices().filter(\.manual)
    }

    /// Every device row in the team (manual and self-registered). Internal; the
    /// public `list()` filters to manual remotes.
    private func allDevices() async throws -> [RemoteSummary] {
        let (data, http) = try await request("GET", path: "/api/devices")
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let devices = obj["devices"] as? [[String: Any]] else {
            throw RemotesClientError.malformedResponse("missing `devices` array")
        }
        return devices.map { device in
            let instances = (device["instances"] as? [[String: Any]]) ?? []
            // A device may have multiple instances (tags); surface the most
            // recently seen instance's routes/tag in the flattened row.
            let primary = instances.first
            let routes = Self.parseDisplayRoutes(primary?["routes"])
            let labels = device["labels"] as? [String: Any]
            let manual = (labels?["manual"] as? Bool) ?? false
            // For manual remotes the instance `tag` is a fixed internal value;
            // the user's display tag (if any) is stored in the instance labels.
            let instanceLabels = primary?["labels"] as? [String: Any]
            let displayTag = (instanceLabels?["tag"] as? String) ?? (primary?["tag"] as? String)
            return RemoteSummary(
                deviceId: (device["deviceId"] as? String) ?? "",
                displayName: device["displayName"] as? String,
                platform: (device["platform"] as? String) ?? "?",
                tag: displayTag,
                routes: routes,
                lastSeen: (primary?["lastSeenAt"] as? String) ?? (device["lastSeenAt"] as? String),
                manual: manual
            )
        }
    }

    /// Create or update a remote under the given name with the given routes.
    /// Idempotent on `name` (the device UUID is derived from the name), so
    /// re-adding refreshes the routes in place. Returns the device UUID.
    @discardableResult
    func add(name rawName: String, routes routeStrings: [String], tag rawTag: String?) async throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RemotesClientError.emptyName }
        guard !routeStrings.isEmpty else { throw RemotesClientError.noRoutes }

        let specs = try routeStrings.map { try RemoteRouteSpec.parse($0) }
        // Await the auth bootstrap/token path FIRST. `currentTokens()` waits for
        // launch session restore; on a refresh-token-only start `currentUser` is
        // nil until then, so reading the owner id before this could mint an
        // unsalted (name-only) device id and break per-user idempotency. After
        // this await `currentUser` reflects the restored session.
        do {
            _ = try await auth.currentTokens()
        } catch AuthError.networkError {
            throw RemotesClientError.sessionRefreshFailed
        } catch {
            throw RemotesClientError.notSignedIn
        }
        let ownerID = await auth.currentUser?.id
        let deviceId = Self.deviceId(forName: name, ownerID: ownerID)
        let attachRoutes = try specs.enumerated().map { index, spec in
            try spec.attachRoute(id: "manual-\(index)", priority: index)
        }
        // A registry route is only attachable from a signed-in phone when the
        // iOS auth policy will send the Stack token over it. Reject anything
        // else here so we never register a remote that shows in the device list
        // but deterministically fails to connect (`insecureManualRoute`).
        for spec in specs where !spec.isTailscaleAttachable {
            throw RemotesClientError.notAttachable(host: spec.host)
        }

        // A manual remote is a SINGLE registry entry. The backend keys instances
        // by `(deviceId, tag)` and the iOS refresh returns nil when a device has
        // 2+ non-empty instances (it can't pick a tagged app), so letting the
        // user's `--tag` drive the instance key would leave a stale instance on
        // a tag change and silently disable registry routes for that remote.
        // Pin a fixed instance tag and carry the user's `--tag` as an instance
        // label, so re-adding the same name always updates the one instance.
        var body: [String: Any] = [
            "deviceId": deviceId,
            "platform": "mac",
            "displayName": name,
            "manual": true,
            "tag": Self.manualInstanceTag,
            "routes": attachRoutes.map(\.mobileHostJSONObject),
        ]
        if let tag = rawTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            body["instanceLabels"] = ["tag": tag]
        }

        let (data, http) = try await request("POST", path: "/api/devices", jsonBody: body)
        try ensureOK(http, data: data)
        return deviceId
    }

    /// The fixed instance tag for every manual remote, so re-adding the same
    /// name updates one instance regardless of the user's display `--tag`.
    static let manualInstanceTag = "cmux-remotes-manual"

    /// Remove a remote by display name or device UUID. Resolves a name to its
    /// device UUID via the registry list first, then DELETEs. Returns the
    /// removed device UUID.
    @discardableResult
    func remove(target rawTarget: String) async throws -> String {
        let target = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw RemotesClientError.notFound(rawTarget) }

        let deviceId = try await resolveDeviceId(target: target)
        let (data, http) = try await request("DELETE", path: "/api/devices", jsonBody: ["deviceId": deviceId])
        try ensureOK(http, data: data)
        // The DELETE is idempotent and returns ok even when nothing was removed
        // (a not-owned id, or a row deleted concurrently). Report the truth from
        // `deleted` so the CLI never claims success when the remote is still
        // listed (e.g. another member's deviceId seen via `remotes list`).
        let obj = try? decodeJSONObject(data)
        let deleted = (obj?["deleted"] as? Int) ?? Int((obj?["deleted"] as? Double) ?? 1)
        if deleted < 1 {
            throw RemotesClientError.notFound(target)
        }
        return deviceId
    }

    // MARK: - Resolution

    /// Resolve a `name-or-deviceId` target to a MANUAL remote's device UUID.
    /// Only manual remotes (added via `cmux remotes add`) are candidates, so this
    /// command can never delete a self-registered Mac's registry row and break
    /// the phone's reconnect.
    private func resolveDeviceId(target: String) async throws -> String {
        // Resolve against the team's MANUAL remotes so removal reports success
        // only when a manual row this caller can delete exists. The DELETE
        // endpoint is idempotent and userId-scoped (it returns ok with
        // deleted=0 for a not-owned/unknown id), so this pre-check is what turns
        // a no-op into a clear not-found.
        let remotes = try await list()
        if Self.isUUID(target) {
            let normalized = target.lowercased()
            if remotes.contains(where: { $0.deviceId.lowercased() == normalized }) {
                return normalized
            }
            throw RemotesClientError.notFound(target)
        }
        // Await bootstrap so the owner salt matches the one used at add time
        // (mirrors `add`); on a refresh-token-only start `currentUser` is nil
        // until the session restores.
        do {
            _ = try await auth.currentTokens()
        } catch AuthError.networkError {
            throw RemotesClientError.sessionRefreshFailed
        } catch {
            throw RemotesClientError.notSignedIn
        }
        // Prefer the deterministic id THIS name was added under (the caller's own
        // manual remote), so a duplicate manual name shared with a co-member does
        // not shadow the user's own remote.
        let ownerID = await auth.currentUser?.id
        let derived = Self.deviceId(forName: target, ownerID: ownerID)
        if remotes.contains(where: { $0.deviceId.lowercased() == derived }) {
            return derived
        }
        // Fall back to an exact display-name match among manual remotes only
        // (case-insensitive). Safe because `list()` excludes self-registered
        // devices and DELETE is userId-scoped.
        if let match = remotes.first(where: {
            ($0.displayName ?? "").compare(target, options: .caseInsensitive) == .orderedSame
        }) {
            return match.deviceId
        }
        throw RemotesClientError.notFound(target)
    }

    // MARK: - Deterministic device id

    /// A stable lowercase UUIDv5 derived from the remote name (and the owning
    /// user), so `remotes add` is idempotent on the name PER USER. RFC 4122 v5
    /// (SHA-1, namespace + name).
    ///
    /// `ownerID` (the Stack user id) is folded into the name so two members of
    /// the same team can each register a common name like `studio`: the device
    /// row is keyed by `(teamId, deviceUuid)` and POST rejects updates to a row
    /// owned by another user, so a name-only id would make the second member's
    /// add collide with the first member's row (`device_not_owned`). Salting by
    /// owner gives each user their own deterministic id while keeping per-user
    /// idempotency. A nil/empty owner falls back to a name-only id (no signed-in
    /// user is an error path that never reaches a successful add).
    static func deviceId(forName name: String, ownerID: String? = nil) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let owner = (ownerID?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        // Length-prefix the owner so distinct (owner, name) pairs cannot alias
        // by concatenation (e.g. owner "ab"+name "c" vs owner "a"+name "bc").
        let seed = owner.isEmpty ? normalized : "\(owner.count):\(owner)\u{1F}\(normalized)"
        var bytes = [UInt8]()
        withUnsafeBytes(of: remoteNamespace.uuid) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(seed.utf8))
        var digest = Array(Insecure.SHA1.hash(data: Data(bytes)))
        // Set version (5) and RFC 4122 variant bits.
        digest[6] = (digest[6] & 0x0F) | 0x50
        digest[8] = (digest[8] & 0x3F) | 0x80
        let uuid = uuid_t(
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: uuid).uuidString.lowercased()
    }

    static func isUUID(_ value: String) -> Bool {
        UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    // MARK: - Display parsing

    /// Extract displayable host:port routes from a stored `routes` jsonb value,
    /// tolerating both `{type:"host_port",host,port}` and `{host,port}` shapes.
    static func parseDisplayRoutes(_ raw: Any?) -> [RemoteRouteDisplay] {
        guard let array = raw as? [[String: Any]] else { return [] }
        return array.compactMap { route in
            guard let endpoint = route["endpoint"] as? [String: Any] else { return nil }
            guard let host = endpoint["host"] as? String, !host.isEmpty else { return nil }
            let port: Int
            if let p = endpoint["port"] as? Int {
                port = p
            } else if let p = endpoint["port"] as? Double {
                port = Int(p)
            } else if let p = endpoint["port"] as? String, let parsed = Int(p) {
                port = parsed
            } else {
                return nil
            }
            return RemoteRouteDisplay(host: host, port: port)
        }
    }

    // MARK: - HTTP

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await auth.currentTokens()
        } catch AuthError.networkError {
            throw RemotesClientError.sessionRefreshFailed
        } catch {
            throw RemotesClientError.notSignedIn
        }
        let teamID = await auth.resolvedTeamID

        guard var comps = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            throw RemotesClientError.malformedResponse("bad vmAPIBaseURL")
        }
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + path
        guard let url = comps.url else {
            throw RemotesClientError.malformedResponse("could not build URL for \(path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                let base = "\(AuthEnvironment.vmAPIBaseURL.scheme ?? "http")://\(AuthEnvironment.vmAPIBaseURL.host ?? "?"):\(AuthEnvironment.vmAPIBaseURL.port ?? -1)"
                throw RemotesClientError.backendUnreachable(url: base, detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw RemotesClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw RemotesClientError.httpStatus(http.statusCode, body)
        }
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw RemotesClientError.malformedResponse("expected JSON object, got \(type(of: parsed))")
        }
        return obj
    }

    /// Map a registry HTTP error to an actionable CLI message.
    static func formatHTTPError(status: Int, body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var errorCode: String?
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            errorCode = object["error"] as? String
        }
        switch errorCode {
        case "loopback_route_rejected":
            return "The device registry rejected a loopback route. Use the Mac's Tailscale address, not localhost."
        case "non_attachable_route_rejected":
            return "The device registry rejected a non-Tailscale route. Use a 100.64.x.x-100.127.x.x (CGNAT) IP or a *.ts.net name; a phone can only attach over Tailscale."
        case "device_not_owned":
            return "That remote is owned by another team member and cannot be modified from this account."
        case "too_many_devices":
            return "This team has reached the maximum number of registered remotes. Remove one with `cmux remotes remove <name>` first."
        case "team_not_found":
            return "You are not a member of the requested team. Run `cmux auth status` to check the signed-in account."
        default:
            break
        }
        if status == 401 {
            return "Not signed in or session expired. Run `cmux auth login`, then retry."
        }
        return "Device registry request failed (HTTP \(status)): \(trimmed.isEmpty ? "<empty>" : trimmed)"
    }
}
