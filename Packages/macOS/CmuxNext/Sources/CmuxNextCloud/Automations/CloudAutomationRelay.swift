public import Foundation

/// Forwards cmux Cloud automation ops for `cmux automation --target cloud`, the Automations page and
/// the Chief's automation tool (docs/automations-platonic-ideal.md, Cloud slice): the app's
/// `cloud.automation` control method.
///
/// A CLI process has no account token; the app calls the API Worker as the signed-in user. Only the
/// ops in ``reads`` and ``mutations`` pass: reads go to `/v1/read`, mutations to `/v1/ops` with the
/// caller's idempotency key, so a retried command applies once. The answer is always one JSON
/// object, `{ok: true, value}` or `{ok: false, error: {code, message, details?}}`: a refusal by the
/// owner keeps its `details` (a plan refusal's checkout link), and a request refused here (an op not
/// forwarded, a mutation without a key, signed out) has the same shape.
///
/// ```swift
/// let relay = CloudAutomationRelay.signedIn(auth)
/// let answer = await relay.forward(#"{"op":"automation.list","params":{}}"#.data(using: .utf8)!)
/// ```
public struct CloudAutomationRelay: Sendable {
    /// Reads, answered from `/v1/read`.
    public static let reads: Set<String> = [
        "automation.list", "automation.get", "automation.runs.list", "automation.webhook.get",
        "run.list", "run.get", "chief.list",
    ]
    /// Mutations, sent to `/v1/ops`. `automation.deploy` and `automation.settings.set` stay out.
    public static let mutations: Set<String> = ["automation.create", "automation.update", "automation.delete", "automation.run"]

    /// One HTTP POST: the path (`v1/ops` or `v1/read`) and the JSON body; the answer's bytes and HTTP status.
    public typealias Post = @Sendable (String, Data) async throws -> (body: Data, status: Int)

    private let post: Post

    /// Makes a relay over `post`.
    ///
    /// - Parameter post: The signed-in POST; tests pass a recorder.
    public init(post: @escaping Post) {
        self.post = post
    }

    /// The relay over a signed-in ``CloudAuth``: the API Worker its configuration names, the current
    /// access token per call (never stored), a no-store URL session.
    @MainActor
    public static func signedIn(_ auth: CloudAuth) -> CloudAutomationRelay {
        let base = auth.configuration.ownerAPIBaseURL()
        let token: @Sendable () async throws -> String? = { @MainActor [weak auth] in
            guard let auth, auth.isSignedIn else { return nil }
            return try await auth.tokens().access
        }
        return CloudAutomationRelay { path, body in
            guard let bearer = try await token() else { throw CloudAutomationRelayError.signedOut }
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "authorization")
            request.httpBody = body
            let (data, response) = try await CloudAPIClient.noStoreTransport.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    /// Where a request goes, or the refusal (`code`, `message`) when it goes nowhere.
    ///
    /// - Parameter request: `{op, params?, idempotency_key?}` as a JSON object.
    /// - Returns: The path and body to post, or the refusal.
    public static func route(_ request: [String: Any]) -> Result<(path: String, body: Data), CloudAutomationRefusal> {
        guard let op = request["op"] as? String, !op.isEmpty else { return .failure(.init("invalid_params", "cloud.automation needs `op`")) }
        let params = request["params"] ?? [String: Any]()
        guard params is [String: Any] else { return .failure(.init("invalid_params", "`params` must be an object")) }
        var body: [String: Any] = ["op": op, "params": params]
        let path: String
        if reads.contains(op) {
            path = "v1/read"
        } else if mutations.contains(op) {
            guard let key = request["idempotency_key"] as? String, !key.isEmpty, key.count <= 200 else {
                return .failure(.init("invalid_params", "\(op) needs `idempotency_key` (at most 200 characters), so a retry applies once"))
            }
            path = "v1/ops"
            body["idempotency_key"] = key
            body["origin"] = "cli"
        } else {
            return .failure(.init("automation.op_not_allowed", "cloud.automation forwards only automation ops; \(op) is not one"))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failure(.init("invalid_params", "`params` is not JSON")) }
        return .success((path, data))
    }

    /// Forwards one request.
    ///
    /// - Parameter request: `{op, params?, idempotency_key?}` as JSON bytes.
    /// - Returns: `{ok: true, value}` or `{ok: false, error: {code, message, details?}}` as JSON bytes.
    public func forward(_ request: Data) async -> Data {
        guard let object = (try? JSONSerialization.jsonObject(with: request)) as? [String: Any] else {
            return Self.encode(.init("invalid_params", "the request is not a JSON object"))
        }
        let routed: (path: String, body: Data)
        switch Self.route(object) {
        case let .success(found): routed = found
        case let .failure(refusal): return Self.encode(refusal)
        }
        let reply: (body: Data, status: Int)
        do {
            reply = try await post(routed.path, routed.body)
        } catch CloudAutomationRelayError.signedOut {
            return Self.encode(.init("automation.signed_out", "sign in to cmux to use Cloud automations"))
        } catch {
            return Self.encode(.init("owner.unreachable", String(describing: error)))
        }
        let answer = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        let succeeded = (200..<300).contains(reply.status) && answer?["error"] == nil && answer?["ok"] as? Bool != false
        guard let answer, succeeded else {
            // A refusal: the owner's error object, a plain error string, or only the HTTP status.
            var refusal: [String: Any] = ["code": "http_\(reply.status)", "message": "cmux Cloud answered HTTP \(reply.status)"]
            if let error = answer?["error"] as? [String: Any] {
                refusal["code"] = error["code"] as? String ?? refusal["code"]
                refusal["message"] = error["message"] as? String ?? ""
                if let details = error["details"] { refusal["details"] = details }
            } else if let text = answer?["error"] as? String {
                refusal["message"] = text
            } else if answer == nil, (200..<300).contains(reply.status) {
                return Self.encode(.init("owner.bad_reply", "cmux Cloud answered something that is not a JSON object"))
            }
            return Self.json(["ok": false, "error": refusal])
        }
        return Self.json(["ok": true, "value": answer["value"] ?? NSNull()])
    }

    private static func encode(_ refusal: CloudAutomationRefusal) -> Data {
        json(["ok": false, "error": ["code": refusal.code, "message": refusal.message]])
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data(#"{"ok":false,"error":{"code":"owner.bad_reply","message":""}}"#.utf8)
    }
}

/// Why a signed-in POST was not sent.
enum CloudAutomationRelayError: Error {
    /// No cmux account is signed in.
    case signedOut
}
