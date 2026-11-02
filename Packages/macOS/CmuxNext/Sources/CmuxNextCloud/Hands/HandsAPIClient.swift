public import Foundation

/// The owner's hand routes on the API Worker (backend hand-routes.ts, docs/chief-hands.md), called
/// with the person's own session: the routes refuse an install token or a Chief token. Ids are
/// checked before a path is built; nothing is cached, no cookie is kept, no redirect is followed
/// and nothing is retried. Answers `{ok: true, value}` or throws ``CloudAPIError/http(status:code:message:action:traceId:)``.
public struct HandsAPIClient: Sendable {
    public typealias AccessToken = @Sendable () async throws -> String

    public let baseURL: URL
    let accessToken: AccessToken

    public init(baseURL: URL, accessToken: @escaping AccessToken) {
        self.baseURL = baseURL
        self.accessToken = accessToken
    }

    /// `GET /v1/hands`.
    public func hands() async throws -> [HandSummary] {
        let value = try await request("GET", "/v1/hands")
        return try JSONDecoder().decode([HandSummary].self, from: JSONSerialization.data(withJSONObject: value))
    }

    /// `GET /v1/hands/<hand>/approvals`: the requests waiting for the owner.
    public func approvals(hand: String) async throws -> [HandApproval] {
        try checkHand(hand)
        let rows = try await request("GET", "/v1/hands/\(hand)/approvals") as? [[String: Any]] ?? []
        return rows.compactMap { HandApproval($0, hand: hand) }
    }

    /// `POST /v1/hands/<hand>/approvals/<id>`: deny `{allow: false}`; allow with the install proof.
    public func answer(hand: String, id: String, allow: Bool, install: String? = nil, signature: String? = nil) async throws {
        try checkHand(hand)
        guard HandIDs.isApproval(id) else { throw CloudAPIError.transport("not a hand approval id") }
        var body: [String: Any] = ["allow": allow]
        if let install, let signature { (body["install"], body["signature"]) = (install, signature) }
        _ = try await request("POST", "/v1/hands/\(hand)/approvals/\(id)", body: body)
    }

    /// `POST /v1/hands/<hand>/level-challenge`, or `POST /v1/hands/defaults/<profile>/challenge`
    /// for `default:<profile>`: a single-use nonce for one raise.
    func challenge(target: String) async throws -> String {
        let value = try await request("POST", try Self.challengePath(target)) as? [String: Any]
        guard let nonce = value?["nonce"] as? String, nonce.range(of: #"^[0-9a-f]{16,128}$"#, options: .regularExpression) != nil else {
            throw CloudAPIError.decoding("level challenge without a nonce")
        }
        return nonce
    }

    /// `PUT /v1/hands/<hand>/level` or `PUT /v1/hands/defaults/<profile>`: `{level}`, plus the
    /// presence proof for a raise.
    func setLevel(target: String, level: HandLevel, proof: (install: String, nonce: String, signature: String)?) async throws {
        var body: [String: Any] = ["level": level.rawValue]
        if let proof { (body["install"], body["nonce"], body["signature"]) = (proof.install, proof.nonce, proof.signature) }
        _ = try await request("PUT", try Self.levelPath(target), body: body)
    }

    /// `PUT /v1/hands/presence-key {install, public_jwk, signature}`.
    func registerPresenceKey(install: String, jwk: [String: String], signature: String) async throws {
        _ = try await request("PUT", "/v1/hands/presence-key", body: ["install": install, "public_jwk": jwk, "signature": signature])
    }

    static func challengePath(_ target: String) throws -> String {
        if let profile = defaultProfile(target) { return "/v1/hands/defaults/\(profile.rawValue)/challenge" }
        guard HandIDs.isHand(target) else { throw CloudAPIError.transport("not a hand id") }
        return "/v1/hands/\(target)/level-challenge"
    }

    static func levelPath(_ target: String) throws -> String {
        if let profile = defaultProfile(target) { return "/v1/hands/defaults/\(profile.rawValue)" }
        guard HandIDs.isHand(target) else { throw CloudAPIError.transport("not a hand id") }
        return "/v1/hands/\(target)/level"
    }

    /// The profile of a `default:<profile>` target, else nil.
    static func defaultProfile(_ target: String) -> HandProfile? {
        target.hasPrefix("default:") ? HandProfile(rawValue: String(target.dropFirst("default:".count))) : nil
    }

    private func checkHand(_ hand: String) throws {
        guard HandIDs.isHand(hand) else { throw CloudAPIError.transport("not a hand id") }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Any {
        let access: String
        do { access = try await accessToken() } catch { throw CloudAPIError.notSignedIn }
        guard let url = URL(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw CloudAPIError.transport("bad path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await CloudOwnerAPIClient.transport.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw CloudAPIError.timedOut(path)
        } catch {
            throw CloudAPIError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudAPIError.transport("no HTTP response") }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode), object?["ok"] as? Bool == true, let value = object?["value"] else {
            let error = object?["error"] as? [String: Any]
            throw CloudAPIError.http(status: http.statusCode, code: error?["code"] as? String, message: error?["message"] as? String)
        }
        return value
    }
}
