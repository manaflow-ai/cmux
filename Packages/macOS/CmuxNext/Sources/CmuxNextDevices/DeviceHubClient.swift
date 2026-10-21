import CmuxNextCompat
public import Foundation

/// Where the device hub gets the account: the app's Stack Auth access token
/// (CloudAuth's `tokens().access`), exchanged once for a hub session.
public protocol DeviceHubAccountTokenProvider: Sendable {
    func stackAccessToken() async throws -> String
}

/// A token provider from a closure: `DeviceHubAccountToken { try await auth.tokens().access }`.
public struct DeviceHubAccountToken: DeviceHubAccountTokenProvider {
    let body: @Sendable () async throws -> String

    public init(_ body: @escaping @Sendable () async throws -> String) {
        self.body = body
    }

    public func stackAccessToken() async throws -> String { try await body() }
}

/// The hub's account session (`POST /v1/auth/stack`), sent as `Authorization: Bearer`.
public struct DeviceHubAccountSession: Sendable, Equatable {
    public var token: String
    public var userId: String
    public var expiresAt: Date

    public init(token: String, userId: String, expiresAt: Date) {
        self.token = token; self.userId = userId; self.expiresAt = expiresAt
    }
}

/// The device hub's HTTP API (docs/device-hub/PROTOCOL.md). Every call but
/// the account exchange is device-signed; the account session is fetched on
/// first use, renewed a minute before it expires, and fetched again once
/// when the server refuses it.
public actor DeviceHubClient {
    public nonisolated let baseURL: URL
    private nonisolated let signerBox: Mutex<DeviceRequestSigner>
    let tokens: any DeviceHubAccountTokenProvider
    let session: URLSession
    nonisolated let now: @Sendable () -> Date
    private var account: DeviceHubAccountSession?
    private var exchange: Task<DeviceHubAccountSession, any Error>?

    /// Signs every device-scoped request.
    public nonisolated var signer: DeviceRequestSigner { signerBox.withLock { $0 } }
    public nonisolated var identity: DeviceIdentity { signer.identity }

    /// Signs from now on as `identity` (a new device after the hub refused the old one).
    public nonisolated func setIdentity(_ identity: DeviceIdentity) {
        let now = self.now
        signerBox.withLock { $0 = DeviceRequestSigner(identity: identity, now: now) }
    }

    public init(baseURL: URL, identity: DeviceIdentity, tokens: any DeviceHubAccountTokenProvider,
                session: URLSession = DeviceHubClient.transport, now: @escaping @Sendable () -> Date = { Date() }) {
        self.baseURL = baseURL
        signerBox = Mutex(DeviceRequestSigner(identity: identity, now: now))
        self.tokens = tokens
        self.session = session
        self.now = now
    }

    /// No cache, no cookies: requests carry the account session and device signatures.
    public static let transport: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    // MARK: Account

    /// The current account session, exchanging the Stack token when there is none or it is about to end.
    public func accountSession() async throws -> DeviceHubAccountSession {
        if let account, account.expiresAt.timeIntervalSince(now()) > 60 { return account }
        if let exchange { return try await exchange.value }
        let task = Task { try await self.exchangeStackToken() }
        exchange = task
        defer { exchange = nil }
        let fresh = try await task.value
        account = fresh
        return fresh
    }

    /// Forgets the account session (sign-out).
    public func signOut() {
        account = nil
        exchange?.cancel()
        exchange = nil
    }

    private func exchangeStackToken() async throws -> DeviceHubAccountSession {
        let stack: String
        do { stack = try await tokens.stackAccessToken() } catch { throw DeviceHubError.notSignedIn }
        var request = URLRequest(url: url("/v1/auth/stack"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["token": stack])
        let data = try await perform(request)
        struct Answer: Decodable {
            var session: String
            var userId: String
            var expiresAt: Date?
            enum CodingKeys: String, CodingKey { case session, userId, expiresAt }
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                session = try c.decode(String.self, forKey: .session)
                userId = try c.decode(String.self, forKey: .userId)
                expiresAt = c.date(.expiresAt)
            }
        }
        let answer = try decode(Answer.self, data)
        // The session is an hour long (PROTOCOL.md); assume so when the answer has no expiry.
        return DeviceHubAccountSession(token: answer.session, userId: answer.userId,
                                       expiresAt: answer.expiresAt ?? now().addingTimeInterval(3600))
    }

    // MARK: Endpoints

    public func me() async throws -> HubMe {
        try await call("GET", "/v1/me", as: HubMe.self)
    }

    /// Registers or updates this device, signed by the key it registers.
    public func registerDevice(name: String, platform: DevicePlatform) async throws -> HubDevice {
        struct Body: Encodable { var id, name: String; var platform: DevicePlatform; var signingKey, agreementKey: String }
        let identity = signer.identity
        let body = Body(id: identity.id, name: name, platform: platform, signingKey: identity.signingKey,
                        agreementKey: identity.agreementKey)
        return try await call("POST", "/v1/devices", body: body, as: DeviceAnswer.self).device
    }

    public func devices() async throws -> [HubDevice] {
        struct Answer: Decodable { var devices: [HubDevice] }
        return try await call("GET", "/v1/devices", as: Answer.self).devices
    }

    public func renameDevice(_ id: String, name: String) async throws -> HubDevice {
        try await call("PATCH", "/v1/devices/\(segment(id))", body: ["name": name], as: DeviceAnswer.self).device
    }

    public func removeDevice(_ id: String) async throws {
        _ = try await call("DELETE", "/v1/devices/\(segment(id))", as: Empty.self)
    }

    /// Signs this device out (`POST /v1/devices/:id/sign-out`): the hub ends
    /// its sessions at once with `signed_out` and closes its socket; the
    /// device stays registered. Call it before dropping the account session.
    public func signOutDevice() async throws {
        _ = try await call("POST", "/v1/devices/\(segment(signer.identity.id))/sign-out", as: Empty.self)
    }

    /// Turns this device's Mac Screen sharing on or off (only a device changes its own).
    public func setMacScreenShared(_ shared: Bool) async throws -> HubDevice {
        try await call("PUT", "/v1/devices/\(segment(signer.identity.id))/mac-screen", body: ["shared": shared],
                       as: DeviceAnswer.self).device
    }

    public func permissions(host: String) async throws -> [HubPermission] {
        struct Answer: Decodable { var permissions: [HubPermission] }
        return try await call("GET", "/v1/permissions", query: [URLQueryItem(name: "host", value: host)], as: Answer.self).permissions
    }

    public func setPermission(host: String, viewer: String, scope: DeviceScope) async throws -> HubPermission {
        struct Answer: Decodable { var permission: HubPermission }
        return try await call("PUT", "/v1/permissions/\(segment(host))/\(segment(viewer))", body: ["scope": scope],
                              as: Answer.self).permission
    }

    /// From the viewer: asks to see (`view`) or control (`full`) `host`.
    public func requestSession(host: String, scope: SessionScope) async throws -> HubSession {
        struct Body: Encodable { var hostId: String; var scope: SessionScope }
        return try await call("POST", "/v1/sessions", body: Body(hostId: host, scope: scope), as: SessionAnswer.self).session
    }

    /// From the host: answers a pending request. `always` stores the permission with `scope`.
    public func decide(session id: String, decision: SessionDecision, scope: SessionScope) async throws -> HubSession {
        struct Body: Encodable { var decision: SessionDecision; var scope: SessionScope }
        return try await call("POST", "/v1/sessions/\(segment(id))/decision", body: Body(decision: decision, scope: scope),
                              as: SessionAnswer.self).session
    }

    public func endSession(_ id: String, reason: String) async throws {
        _ = try await call("POST", "/v1/sessions/\(segment(id))/end", body: ["reason": reason], as: Empty.self)
    }

    /// Fresh cmux relay credentials for a session (empty on the free plan).
    public func sessionICE(_ id: String) async throws -> [DeviceHubICEServer] {
        struct Answer: Decodable { var ice: [DeviceHubICEServer] }
        return try await call("POST", "/v1/sessions/\(segment(id))/ice", as: Answer.self).ice
    }

    public func relays() async throws -> [HubRelay] {
        struct Answer: Decodable { var relays: [HubRelay] }
        return try await call("GET", "/v1/relays", as: Answer.self).relays
    }

    /// Creates or replaces a relay; `sealed` holds its secret sealed to every device.
    public func putRelay(_ relay: RelayUpdate) async throws -> HubRelay {
        struct Answer: Decodable { var relay: HubRelay }
        return try await call("PUT", "/v1/relays/\(segment(relay.id))", body: relay, as: Answer.self).relay
    }

    public func deleteRelay(_ id: String) async throws {
        _ = try await call("DELETE", "/v1/relays/\(segment(id))", as: Empty.self)
    }

    /// Audit entries, newest first: at most `limit` (1-200), older than `before` (an entry's `ts`),
    /// only those naming `device` as viewer or host when it is given.
    public func audit(limit: Int? = nil, before: Date? = nil, device: String? = nil) async throws -> [AuditEntry] {
        struct Answer: Decodable { var entries: [AuditEntry] }
        var query: [URLQueryItem] = []
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(Int64((before.timeIntervalSince1970 * 1000).rounded())))) }
        // One device's entries (it is the viewer or the host).
        if let device { query.append(URLQueryItem(name: "device", value: device)) }
        return try await call("GET", "/v1/audit", query: query, as: Answer.self).entries
    }

    /// The User DO socket's URL and headers (`GET /v1/user/ws`): the account
    /// session and the device signature, signed now.
    public func userSocketHandshake() async throws -> DeviceHubHandshake {
        let url = socketURL(url("/v1/user/ws"))
        let account = try await accountSession()
        var headers: [String: String]
        do { headers = try signer.headers(method: "GET", pathAndQuery: DeviceRequestSigner.pathAndQuery(of: url), body: nil) } catch {
            throw DeviceHubError.identity("\(error)")
        }
        headers["Authorization"] = "Bearer \(account.token)"
        return DeviceHubHandshake(url: url, headers: headers)
    }

    // MARK: Requests

    /// The signed request for one call.
    func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let account = try await accountSession()
        request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        do { try signer.sign(&request) } catch { throw DeviceHubError.identity("\(error)") }
        return request
    }

    func call<Answer: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], as type: Answer.Type) async throws -> Answer {
        try await call(method, path, query: query, bodyData: nil, as: type)
    }

    func call<Body: Encodable, Answer: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Body,
                                                  as type: Answer.Type) async throws -> Answer {
        let data: Data
        do { data = try JSONEncoder().encode(body) } catch { throw DeviceHubError.decoding("request body: \(error)") }
        return try await call(method, path, query: query, bodyData: data, as: type)
    }

    private func call<Answer: Decodable>(_ method: String, _ path: String, query: [URLQueryItem], bodyData: Data?,
                                         as type: Answer.Type) async throws -> Answer {
        do {
            return try decode(type, try await perform(try await request(method, path, query: query, body: bodyData)))
        } catch let error as DeviceHubError where Self.isAccountRefusal(error) {
            // The hub session ended early (or the server restarted): exchange again, once.
            account = nil
            return try decode(type, try await perform(try await request(method, path, query: query, body: bodyData)))
        }
    }

    /// A 401 that is about the account session, not the device signature.
    static func isAccountRefusal(_ error: DeviceHubError) -> Bool {
        switch error {
        case .notSignedIn: return true
        case .server(401, .unauthorized, _): return true
        case let .server(401, .other(code), _): return code.isEmpty
        default: return false
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch {
            throw DeviceHubError.transport(error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw DeviceHubError.transport("no HTTP response") }
        guard (200 ..< 300).contains(status) else { throw DeviceHubError.from(status: status, data: data) }
        return data
    }

    private func decode<Answer: Decodable>(_ type: Answer.Type, _ data: Data) throws -> Answer {
        do { return try JSONDecoder().decode(type, from: data.isEmpty ? Data("{}".utf8) : data) } catch {
            throw DeviceHubError.decoding("\(Answer.self): \(error)")
        }
    }

    /// `baseURL` with `path` appended to its own path, and `query`.
    nonisolated func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) ?? URLComponents()
        var base = components.percentEncodedPath
        while base.hasSuffix("/") { base.removeLast() }
        components.percentEncodedPath = base + path
        components.queryItems = query.isEmpty ? nil : query
        return components.url ?? baseURL
    }

    /// `https` → `wss`, `http` → `ws`.
    nonisolated func socketURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        switch components.scheme {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: break
        }
        return components.url ?? url
    }

    /// One path segment, percent-encoded.
    nonisolated func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    struct DeviceAnswer: Decodable { var device: HubDevice }
    struct SessionAnswer: Decodable { var session: HubSession }
    struct Empty: Decodable {}
}

/// `PUT /v1/relays/:id`'s body.
public struct RelayUpdate: Encodable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var urls: [String]
    public var authMode: RelayAuthMode
    /// `{deviceId: base64}` for every device (``RelaySealing``).
    public var sealed: [String: String]
    public var enabled: Bool
    public var priority: Int

    public init(id: String, name: String, urls: [String], authMode: RelayAuthMode, sealed: [String: String], enabled: Bool, priority: Int) {
        self.id = id; self.name = name; self.urls = urls; self.authMode = authMode
        self.sealed = sealed; self.enabled = enabled; self.priority = priority
    }

    enum CodingKeys: String, CodingKey { case name, urls, authMode, sealed, enabled, priority }
}

/// A WebSocket's URL and upgrade headers.
public struct DeviceHubHandshake: Sendable, Equatable {
    public var url: URL
    public var headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }

    public var request: URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }
}
