import CmuxAuthRuntime
import Foundation

enum VMClientError: Error, CustomStringConvertible {
    case notSignedIn
    case backendUnreachable(url: String, detail: String)
    case httpStatus(Int, String)
    case malformedResponse(String)

    var description: String {
        switch self {
        case .notSignedIn:
            return """
                You are not signed in to cmux.

                What to do:
                  cmux auth login
                  cmux auth status
                """
        case .backendUnreachable(let url, let detail):
            return """
                Cannot reach the cmux Cloud VM service at \(url).

                What to do:
                  Start the cmux web server, then retry.
                  If you are using a local development build, check its Cloud VM service URL before launching cmux.

                Details:
                  \(detail)
                """
        case .httpStatus(let code, let body):
            return formattedCloudVMHTTPError(status: code, body: body)
        case .malformedResponse(let message):
            return """
                The cmux Cloud VM backend returned a response this client could not read.

                What to do:
                  Update cmux to the latest build and retry.
                  If this keeps happening, copy the details below and contact support.

                Details:
                  \(message)
                """
        }
    }
}

private func formattedCloudVMHTTPError(status: Int, body: String) -> String {
    let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmedBody.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        return """
            Cloud VM request failed (HTTP \(status)).

            What to do:
              Retry the command. If it keeps failing, copy the response body and contact support.

            Response body:
              \(limitedSingleLine(trimmedBody.isEmpty ? "<empty>" : trimmedBody))
            """
    }

    let errorCode = cloudVMString(object["error"]) ?? "http_\(status)"
    let message = cloudVMString(object["message"])
        ?? cloudVMString(object["reason"])
        ?? defaultCloudVMMessage(status: status)
    let action = cloudVMString(object["action"])
        ?? defaultCloudVMAction(status: status, errorCode: errorCode)
    let details = cloudVMDetails(from: object)

    var lines: [String] = [
        "Cloud VM request failed (HTTP \(status): \(errorCode))",
        message,
    ]
    if !action.isEmpty {
        lines.append("")
        lines.append("What to do:")
        lines.append(contentsOf: indentedActionLines(action))
    }
    if !details.isEmpty {
        lines.append("")
        lines.append("Details:")
        lines.append(contentsOf: details.map { "  \($0)" })
    }
    return lines.joined(separator: "\n")
}

private func defaultCloudVMMessage(status: Int) -> String {
    switch status {
    case 400:
        return "The Cloud VM request was not valid."
    case 401:
        return "cmux could not authenticate this Cloud VM request."
    case 402:
        return "This team cannot create another Cloud VM with the current billing state."
    case 403:
        return "This Cloud VM request was not allowed."
    case 404:
        return "The requested Cloud VM was not found."
    case 409:
        return "Another Cloud VM operation is already running."
    case 500...599:
        return "The Cloud VM service is temporarily unavailable."
    default:
        return "The Cloud VM service returned an error."
    }
}

private func defaultCloudVMAction(status: Int, errorCode: String) -> String {
    switch errorCode {
    case "vm_active_limit_exceeded":
        return "Run `cmux vm ls`, then stop or delete an active VM with `cmux vm rm <id>` before retrying."
    case "vm_not_found":
        return "Run `cmux vm ls` to see available Cloud VMs. If the VM was paused or destroyed, start a fresh one with `cmux vm new`."
    case "vm_billing_team_required":
        return "Select a team in cmux, then retry. You can also run `cmux auth status` to check the signed-in account."
    case "vm_create_credits_insufficient":
        return "Ask a team admin to upgrade the plan or grant more Cloud VM create credits, then retry."
    default:
        if status == 401 {
            return "Run `cmux auth login`, then retry."
        }
        if status == 403 {
            return "Run `cmux auth status` and confirm you are using the expected team."
        }
        return "Retry the command. If it keeps failing, copy this error and contact support."
    }
}

private func cloudVMDetails(from object: [String: Any]) -> [String] {
    let allowedKeys = Set([
        "amount",
        "code",
        "duration",
        "durationMs",
        "field",
        "idempotencyKeySet",
        "imageRequested",
        "limit",
        "operation",
        "retryable",
        "status",
        "type",
        "vmId",
    ])
    var details: [String: Any] = [:]
    func addAllowedDetail(key: String, value: Any) {
        guard allowedKeys.contains(key), !cloudVMIsNull(value) else { return }
        details[key] = value
    }
    if let rawDetails = object["details"] {
        if let nestedDetails = rawDetails as? [String: Any] {
            for (key, value) in nestedDetails {
                addAllowedDetail(key: key, value: value)
            }
        }
    }
    for (key, value) in object {
        addAllowedDetail(key: key, value: value)
    }
    return details.keys.sorted().compactMap { key in
        guard let value = details[key], !cloudVMIsNull(value) else { return nil }
        return "\(key): \(cloudVMValueDescription(value))"
    }
}

private func indentedActionLines(_ action: String) -> [String] {
    action
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "  \($0)" }
}

private func cloudVMString(_ value: Any?) -> String? {
    guard let string = value as? String else { return nil }
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func cloudVMValueDescription(_ value: Any) -> String {
    if let string = value as? String {
        return limitedSingleLine(string)
    }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return "\(number)"
    }
    if cloudVMIsNull(value) {
        return "null"
    }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let encoded = String(data: data, encoding: .utf8) {
        return limitedSingleLine(encoded)
    }
    return limitedSingleLine(String(describing: value))
}

private func cloudVMIsNull(_ value: Any) -> Bool {
    value is NSNull
}

// maxCharacters is measured in Swift Characters so truncation never splits a grapheme cluster.
private func limitedSingleLine(_ value: String, maxCharacters: Int = 1200) -> String {
    let singleLine = value
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    guard singleLine.count > maxCharacters else { return singleLine }
    let index = singleLine.index(singleLine.startIndex, offsetBy: maxCharacters)
    return String(singleLine[..<index]) + "..."
}

struct VMSummary {
    let id: String
    let provider: String
    let status: String
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
/// the injected `AuthCoordinator`; the HTTP base URL from `AuthEnvironment.vmAPIBaseURL`.
///
/// All methods are `async throws` and run off the main actor.
actor VMClient {
    /// Set once by `bootstrap(auth:)` during app startup (AppDelegate
    /// `configure`), before any socket/CLI path can reach the cloud VM client.
    /// Main-actor isolated so every read goes through a compiler-checked hop.
    @MainActor private(set) static var shared: VMClient!

    /// Build the shared client with its injected auth dependency. Call once at
    /// the composition root.
    @MainActor
    static func bootstrap(auth: AuthCoordinator, session: URLSession = .shared) {
        shared = VMClient(session: session, auth: auth)
    }

    private static let createTimeoutSeconds: TimeInterval = 16 * 60
    private static let attachTimeoutSeconds: TimeInterval = 16 * 60

    private let session: URLSession
    private let auth: AuthCoordinator

    init(session: URLSession = .shared, auth: AuthCoordinator) {
        self.session = session
        self.auth = auth
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
                throw VMClientError.malformedResponse("Cloud VM list response was missing required fields for item \(index).")
            }
            guard let provider = dict["provider"] as? String, !provider.isEmpty else {
                throw VMClientError.malformedResponse("Cloud VM list response was missing required fields for item \(index).")
            }
            guard let image = dict["image"] as? String, !image.isEmpty else {
                throw VMClientError.malformedResponse("Cloud VM list response was missing required fields for item \(index).")
            }
            let rawStatus = (dict["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayStatus = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
            let createdAt = (dict["createdAt"] as? Int64)
                ?? Int64((dict["createdAt"] as? Double) ?? 0)
            return VMSummary(id: id, provider: provider, status: displayStatus, image: image, createdAt: createdAt)
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
            throw VMClientError.malformedResponse("Cloud VM create response was missing required fields.")
        }
        // Prefer the server-supplied createdAt. Using the local wall clock caused two
        // visible bugs: (1) creation time was wrong under clock skew, (2) idempotent
        // retries that short-circuited to an existing VM on the server still stamped
        // "now" on the mac side, so the client saw a fresh timestamp for a replayed
        // create (Codex P2). Fall back to the local clock only if the server omits it.
        let serverCreatedAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let createdAt = serverCreatedAt > 0 ? serverCreatedAt : Int64(Date().timeIntervalSince1970 * 1000)
        let rawStatus = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayStatus = rawStatus.flatMap { $0.isEmpty ? nil : $0 } ?? "running"
        return VMSummary(id: id, provider: providerValue, status: displayStatus, image: imageValue, createdAt: createdAt)
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
                throw VMClientError.malformedResponse("Cloud VM attach response was missing required fields.")
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
            throw VMClientError.malformedResponse("Cloud VM attach response used an unsupported transport type.")
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
            tokens = try await auth.currentTokens()
        } catch {
            throw VMClientError.notSignedIn
        }
        let teamID = await auth.resolvedTeamID

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
            throw VMClientError.malformedResponse("Cloud VM attach response was missing required fields.")
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
            throw VMClientError.malformedResponse("Cloud VM SSH response was missing required fields.")
        }
        let credential: VMSSHEndpoint.Credential
        switch kind {
        case "password":
            guard let value = credDict["value"] as? String else {
                throw VMClientError.malformedResponse("Cloud VM SSH response was missing required fields.")
            }
            credential = .password(value)
        case "authorizedKey":
            guard let pem = credDict["privateKeyPem"] as? String else {
                throw VMClientError.malformedResponse("Cloud VM SSH response was missing required fields.")
            }
            credential = .authorizedKey(privateKeyPem: pem)
        default:
            throw VMClientError.malformedResponse("Cloud VM SSH response used an unsupported attach mode.")
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
            throw VMClientError.malformedResponse("Cloud VM SSH response was missing required fields.")
        }
        return port
    }
}
