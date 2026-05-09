import Foundation

enum VMClientError: Error, CustomStringConvertible {
    case notSignedIn
    case backendUnreachable(url: String, detail: String)
    case httpStatus(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .notSignedIn:
            return "Not signed in. Run `cmux auth login` first."
        case .backendUnreachable(let url, let detail):
            return """
                Cannot reach cmux backend at \(url). Is the dev server running?
                  • In this shell: export CMUX_VM_API_BASE_URL=http://localhost:<port>
                  • Then relaunch the cmux app so it inherits the env.
                (underlying: \(detail))
                """
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .malformedResponse(let message):
            return "Malformed response: \(message)"
        }
    }
}

struct VMSummary {
    let id: String
    let provider: String
    let image: String
    let createdAt: Int64
}

struct VMExecResult {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

/// Short-lived SSH endpoint the backend mints on demand. Mac client dials this with the
/// existing `cmux ssh` transport.
struct VMSSHEndpoint {
    let transport: String
    let host: String
    let port: Int
    let username: String
    let credential: Credential
    let publicKeyFingerprint: String?

    enum Credential {
        case password(String)
        case authorizedKey(privateKeyPem: String)
    }
}

struct VMWebSocketPtyEndpoint {
    let transport: String
    let url: String
    let headers: [String: String]
    let token: String
    let sessionId: String
    let expiresAtUnix: Int64
    let daemon: VMWebSocketDaemonEndpoint?
}

struct VMWebSocketDaemonEndpoint {
    let url: String
    let headers: [String: String]
    let token: String
    let sessionId: String
    let expiresAtUnix: Int64
}

enum VMAttachEndpoint {
    case ssh(VMSSHEndpoint)
    case websocket(VMWebSocketPtyEndpoint)
}

/// Talks to the manaflow cloud VM backend at `/api/vm/*`. Stack Auth tokens come from
/// `AuthManager.shared`; the HTTP base URL from `AuthEnvironment.vmAPIBaseURL`.
///
/// All methods are `async throws` and run off the main actor.
actor VMClient {
    static let shared = VMClient()
    private static let createTimeoutSeconds: TimeInterval = 16 * 60
    private static let attachTimeoutSeconds: TimeInterval = 16 * 60

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func list() async throws -> [VMSummary] {
        let (data, http) = try await request("GET", path: "/api/vm")
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let items = obj["vms"] as? [[String: Any]] else {
            throw VMClientError.malformedResponse("missing `vms` array")
        }
        return try items.enumerated().map { index, dict -> VMSummary in
            guard let id = dict["id"] as? String, !id.isEmpty else {
                throw VMClientError.malformedResponse("missing `id` in /api/vm item \(index)")
            }
            guard let provider = dict["provider"] as? String, !provider.isEmpty else {
                throw VMClientError.malformedResponse("missing `provider` in /api/vm item \(index)")
            }
            guard let image = dict["image"] as? String, !image.isEmpty else {
                throw VMClientError.malformedResponse("missing `image` in /api/vm item \(index)")
            }
            let createdAt = (dict["createdAt"] as? Int64)
                ?? Int64((dict["createdAt"] as? Double) ?? 0)
            return VMSummary(id: id, provider: provider, image: image, createdAt: createdAt)
        }
    }

    func create(image: String? = nil, provider: String? = nil, idempotencyKey: String) async throws -> VMSummary {
        var body: [String: Any] = [:]
        if let image { body["image"] = image }
        if let provider { body["provider"] = provider }
        // The CLI owns key stability across command retries. VMClient only forwards the
        // key so the backend can short-circuit duplicate paid provider creates.
        let headers = ["Idempotency-Key": idempotencyKey]
        let (data, http) = try await request(
            "POST",
            path: "/api/vm",
            jsonBody: body,
            extraHeaders: headers,
            timeoutSeconds: Self.createTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let id = obj["id"] as? String,
              let providerValue = obj["provider"] as? String,
              let imageValue = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("missing id/provider/image on POST /api/vm response")
        }
        // Prefer the server-supplied createdAt. Using the local wall clock caused two
        // visible bugs: (1) creation time was wrong under clock skew, (2) idempotent
        // retries that short-circuited to an existing VM on the server still stamped
        // "now" on the mac side, so the client saw a fresh timestamp for a replayed
        // create (Codex P2). Fall back to the local clock only if the server omits it.
        let serverCreatedAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let createdAt = serverCreatedAt > 0 ? serverCreatedAt : Int64(Date().timeIntervalSince1970 * 1000)
        return VMSummary(id: id, provider: providerValue, image: imageValue, createdAt: createdAt)
    }

    func destroy(id: String) async throws {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request("DELETE", path: "/api/vm/\(encodedID)")
        try ensureOK(http, data: data)
    }

    func openSSH(id: String) async throws -> VMSSHEndpoint {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request("POST", path: "/api/vm/\(encodedID)/ssh-endpoint", jsonBody: [:])
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        return try decodeSSHEndpoint(obj)
    }

    func openAttach(id: String, requireDaemon: Bool = false) async throws -> VMAttachEndpoint {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(encodedID)/attach-endpoint",
            jsonBody: ["requireDaemon": requireDaemon],
            timeoutSeconds: Self.attachTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        let transport = (obj["transport"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch transport {
        case "ssh":
            return .ssh(try decodeSSHEndpoint(obj))
        case "websocket":
            guard let url = obj["url"] as? String,
                  let token = obj["token"] as? String,
                  let sessionId = obj["sessionId"] as? String else {
                throw VMClientError.malformedResponse("attach-endpoint websocket missing url/token/sessionId: \(obj)")
            }
            let rawHeaders = obj["headers"] as? [String: Any] ?? [:]
            let headers = rawHeaders.reduce(into: [String: String]()) { result, pair in
                if let value = pair.value as? String {
                    result[pair.key] = value
                }
            }
            let expiresAtUnix = (obj["expiresAtUnix"] as? Int64)
                ?? Int64((obj["expiresAtUnix"] as? Double) ?? 0)
            let daemon = try decodeWebSocketDaemonEndpoint(obj["daemon"])
            return .websocket(VMWebSocketPtyEndpoint(
                transport: "websocket",
                url: url,
                headers: headers,
                token: token,
                sessionId: sessionId,
                expiresAtUnix: expiresAtUnix,
                daemon: daemon
            ))
        default:
            throw VMClientError.malformedResponse("attach-endpoint unknown transport: \(String(describing: transport))")
        }
    }

    func exec(id: String, command: String, timeoutMs: Int = 30_000) async throws -> VMExecResult {
        let body: [String: Any] = ["command": command, "timeoutMs": timeoutMs]
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(encodedID)/exec",
            jsonBody: body,
            timeoutSeconds: max(1, Double(timeoutMs) / 1000.0 + 5.0)
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        let exitCode = (obj["exitCode"] as? Int) ?? ((obj["exitCode"] as? Double).map(Int.init) ?? -1)
        let stdout = (obj["stdout"] as? String) ?? ""
        let stderr = (obj["stderr"] as? String) ?? ""
        return VMExecResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
    }

    // MARK: - HTTP

    private func request(
        _ method: String,
        path: String,
        jsonBody: [String: Any]? = nil,
        extraHeaders: [String: String] = [:],
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let tokens: (accessToken: String, refreshToken: String)
        do {
            tokens = try await AuthManager.shared.currentTokens()
        } catch {
            throw VMClientError.notSignedIn
        }
        let teamID = await AuthManager.shared.resolvedTeamID

        guard var url = URLComponents(url: AuthEnvironment.vmAPIBaseURL, resolvingAgainstBaseURL: false) else {
            throw VMClientError.malformedResponse("bad vmAPIBaseURL")
        }
        url.path = (url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path) + path
        guard let resolved = url.url else {
            throw VMClientError.malformedResponse("could not build URL for \(path)")
        }

        var req = URLRequest(url: resolved)
        req.httpMethod = method
        if let timeoutSeconds {
            req.timeoutInterval = timeoutSeconds
        }
        req.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(tokens.refreshToken, forHTTPHeaderField: "X-Stack-Refresh-Token")
        if let teamID, !teamID.isEmpty {
            req.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody, options: [])
        }
        for (key, value) in extraHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError {
            // Surface unreachable-backend errors as a human-readable message with recovery steps
            // instead of the verbose NSURLErrorDomain payload.
            switch error.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet:
                let base = "\(AuthEnvironment.vmAPIBaseURL.scheme ?? "http")://\(AuthEnvironment.vmAPIBaseURL.host ?? "?"):\(AuthEnvironment.vmAPIBaseURL.port ?? -1)"
                throw VMClientError.backendUnreachable(url: base, detail: error.localizedDescription)
            default:
                throw error
            }
        }
        guard let http = response as? HTTPURLResponse else {
            throw VMClientError.malformedResponse("non-HTTP response")
        }
        return (data, http)
    }

    private func decodeWebSocketDaemonEndpoint(_ value: Any?) throws -> VMWebSocketDaemonEndpoint? {
        guard let obj = value as? [String: Any] else { return nil }
        guard let url = obj["url"] as? String,
              let token = obj["token"] as? String,
              let sessionId = obj["sessionId"] as? String else {
            throw VMClientError.malformedResponse("attach-endpoint websocket daemon missing url/token/sessionId: \(obj)")
        }
        let rawHeaders = obj["headers"] as? [String: Any] ?? [:]
        let headers = rawHeaders.reduce(into: [String: String]()) { result, pair in
            if let headerValue = pair.value as? String {
                result[pair.key] = headerValue
            }
        }
        let expiresAtUnix = (obj["expiresAtUnix"] as? Int64)
            ?? Int64((obj["expiresAtUnix"] as? Double) ?? 0)
        return VMWebSocketDaemonEndpoint(
            url: url,
            headers: headers,
            token: token,
            sessionId: sessionId,
            expiresAtUnix: expiresAtUnix
        )
    }

    private func ensureOK(_ http: HTTPURLResponse, data: Data) throws {
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw VMClientError.httpStatus(http.statusCode, body)
        }
    }

    private func decodeJSONObject(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        guard let obj = parsed as? [String: Any] else {
            throw VMClientError.malformedResponse("expected JSON object, got \(type(of: parsed))")
        }
        return obj
    }

    private func decodeSSHEndpoint(_ obj: [String: Any]) throws -> VMSSHEndpoint {
        let port = try decodePort(obj["port"])
        guard let host = obj["host"] as? String,
              let username = obj["username"] as? String,
              let credDict = obj["credential"] as? [String: Any],
              let kind = credDict["kind"] as? String
        else {
            throw VMClientError.malformedResponse("ssh-endpoint missing fields: \(obj)")
        }
        let credential: VMSSHEndpoint.Credential
        switch kind {
        case "password":
            guard let value = credDict["value"] as? String else {
                throw VMClientError.malformedResponse("ssh-endpoint password credential missing value")
            }
            credential = .password(value)
        case "authorizedKey":
            guard let pem = credDict["privateKeyPem"] as? String else {
                throw VMClientError.malformedResponse("ssh-endpoint authorizedKey credential missing privateKeyPem")
            }
            credential = .authorizedKey(privateKeyPem: pem)
        default:
            throw VMClientError.malformedResponse("ssh-endpoint unknown credential kind: \(kind)")
        }
        return VMSSHEndpoint(
            transport: "ssh",
            host: host,
            port: port,
            username: username,
            credential: credential,
            publicKeyFingerprint: obj["publicKeyFingerprint"] as? String
        )
    }

    private func pathSegment(_ value: String, fieldName: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw VMClientError.malformedResponse("invalid \(fieldName)")
        }
        return encoded
    }

    private func decodePort(_ raw: Any?) throws -> Int {
        let port: Int?
        if let int = raw as? Int {
            port = int
        } else if let double = raw as? Double {
            port = Int(exactly: double)
        } else {
            port = nil
        }
        guard let port, (1...65_535).contains(port) else {
            throw VMClientError.malformedResponse("ssh-endpoint invalid port: \(String(describing: raw))")
        }
        return port
    }
}
