import Foundation

/// The HTTP half of `cmux.wire/1` for ``WireHomeSource``: `POST /v1/ops`,
/// `POST /v1/read`, `GET /v1/selfhost/info`, the attachment routes and the
/// socket upgrade request. It adds the auth of ``HomeWireAuth`` (a Bearer
/// for `.stack`, nothing for `.tailscale`) and turns every answer into a
/// value or a ``HomeRejection``, the same way the daemon's proxy does
/// (cmux-tui-cloud-conversations `contract.rs`).
struct HomeWireClient: Sendable {
    /// What a request does, for the refusal a lost answer becomes.
    enum Effect: Sendable {
        /// A read: a lost answer is `ownerUnreachable` (nothing changed).
        case read
        /// A mutation: a lost answer is `indeterminate` (it may have committed).
        case mutation
    }

    let baseURL: URL
    let auth: HomeWireAuth
    let http: any HomeWireHTTP

    // MARK: Requests

    /// `base` + `path` (the base may carry a path prefix).
    func url(_ path: String) -> URL {
        var text = baseURL.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + path) ?? baseURL
    }

    /// A request with this server's auth. `.tailscale` sends no
    /// `Authorization` header at all: the server knows the caller by its
    /// tailnet address.
    func authorized(_ request: URLRequest, forceRefresh: Bool) async throws -> URLRequest {
        var request = request
        switch auth {
        case .stack(let tokens):
            let token: String
            do {
                token = try await tokens.accessToken(forceRefresh: forceRefresh)
            } catch {
                throw HomeRejection.notAuthorized
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .tailscale:
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The WebSocket upgrade for `path` (`ws`/`wss`, subprotocol `cmux.wire.v1`).
    func socketRequest(_ path: String, forceRefresh: Bool) async throws -> URLRequest {
        guard var components = URLComponents(url: url(path), resolvingAgainstBaseURL: false) else {
            throw HomeRejection.invalid("bad_server_url")
        }
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        guard let socketURL = components.url else { throw HomeRejection.invalid("bad_server_url") }
        var request = URLRequest(url: socketURL)
        request.setValue("cmux.wire.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return try await authorized(request, forceRefresh: forceRefresh)
    }

    /// Sends `request` with auth; a 401 asks for a new token once and tries again.
    func exchange(_ request: URLRequest, effect: Effect,
                  send: @Sendable (URLRequest) async throws -> HomeWireHTTPReply) async throws -> HomeWireHTTPReply {
        var forceRefresh = false
        // wakeup-allow: bounded at most two exchanges: a 401 asks for a new token once, then it returns
        while true {
            let signed = try await authorized(request, forceRefresh: forceRefresh)
            let reply: HomeWireHTTPReply
            do {
                reply = try await send(signed)
            } catch let rejection as HomeRejection {
                throw rejection
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw effect == .read ? HomeRejection.ownerUnreachable : HomeRejection.indeterminate
            }
            if reply.status == 401, case .stack = auth, !forceRefresh {
                forceRefresh = true
                continue
            }
            return reply
        }
    }

    /// POSTs `body` as JSON to `path` and returns the reply's JSON body.
    func post(_ path: String, _ body: HomeWireJSON, effect: Effect) async throws -> HomeWireJSON {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let http = self.http
        let reply = try await exchange(request, effect: effect) { try await http.send($0) }
        return try Self.check(reply, effect: effect)
    }

    /// `POST /v1/read {op, params}`: the reply's `value`.
    func read(_ op: String, _ params: HomeWireJSON) async throws -> HomeWireJSON {
        let body = try await post("/v1/read", ["op": .string(op), "params": params], effect: .read)
        guard body.object?.keys.contains("value") == true else {
            throw HomeRejection.ownerUnreachable
        }
        return body["value"]
    }

    /// `POST /v1/ops {op, params, idempotency_key, origin}`: the owner's
    /// `value` and whether the key was already decided (a replay).
    func op(_ op: String, _ params: HomeWireJSON, key: IdempotencyKey, origin: String? = "user") async throws
        -> (value: HomeWireJSON, replayed: Bool) {
        var body: [String: HomeWireJSON] = ["op": .string(op), "params": params, "idempotency_key": .string(key.rawValue)]
        if let origin { body["origin"] = .string(origin) }
        let reply = try await post("/v1/ops", .object(body), effect: .mutation)
        return (reply["value"], reply["replayed"].bool ?? false)
    }

    /// `GET /v1/selfhost/info` (self-hosted servers only).
    func selfHostInfo() async throws -> HomeWireSelfHostInfo {
        var request = URLRequest(url: url("/v1/selfhost/info"))
        request.httpMethod = "GET"
        let http = self.http
        let reply = try await exchange(request, effect: .read) { try await http.send($0) }
        let body = try Self.check(reply, effect: .read)
        guard let info = HomeWireSelfHostInfo(body) else { throw HomeRejection.invalid("not_a_selfhost_server") }
        return info
    }

    // MARK: Answers

    /// The JSON body of a 2xx answer whose `ok` is not false, else the refusal.
    static func check(_ reply: HomeWireHTTPReply, effect: Effect) throws -> HomeWireJSON {
        let body = HomeWireJSON.parse(reply.body) ?? .null
        switch reply.status {
        case 200...299:
            if body["ok"].bool == false { throw rejection(body, status: reply.status, retryAfter: reply.retryAfter, effect: effect) }
            return body
        case 401:
            throw HomeRejection.notAuthorized
        case 400...499:
            throw rejection(body, status: reply.status, retryAfter: reply.retryAfter, effect: effect)
        default:
            // A 5xx (or no status): the owner may or may not have applied it.
            throw effect == .read ? HomeRejection.ownerUnreachable : HomeRejection.indeterminate
        }
    }

    /// `{code, message, retryable}` (top level or under `error`) as a refusal.
    static func rejection(_ body: HomeWireJSON, status: Int, retryAfter: TimeInterval?, effect: Effect) -> HomeRejection {
        let error = body["error"].object != nil ? body["error"] : body
        let code = error["code"].string
        if status == 429 || code == "rate_limited" || code == "rate.limited" {
            let afterMs = error["retry_after_ms"].double.map { $0 / 1000 }
            return .rateLimited(retryAfter: retryAfter ?? afterMs)
        }
        guard let code else { return .invalid("http_\(status)") }
        if code == "auth.unauthenticated" { return .notAuthorized }
        if code == "auth.forbidden" || code == "forbidden" { return .invalid(code) }
        // Refused now, may succeed later: the store keeps it and resends with its key.
        if error["retryable"].bool == true { return effect == .read ? .ownerUnreachable : .indeterminate }
        return .invalid(code)
    }
}
