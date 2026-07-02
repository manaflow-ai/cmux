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
    let ui = object["ui"] as? [String: Any]
    let displayTitle = cloudVMString(ui?["title"])
    let message = cloudVMString(object["message"])
        ?? cloudVMString(object["reason"])
        ?? defaultCloudVMMessage(status: status)
    let displayMessage = cloudVMString(ui?["message"]) ?? message
    let action = cloudVMString(object["action"])
        ?? defaultCloudVMAction(status: status, errorCode: errorCode)
    let retryAfterSeconds = cloudVMInt(object["retryAfterSeconds"])
        ?? cloudVMInt(ui?["retryAfterSeconds"])
    let details = cloudVMDetails(from: object)

    var lines: [String] = [
        "\(displayTitle ?? "Cloud VM request failed") (HTTP \(status): \(errorCode))",
        displayMessage,
    ]
    if let retryAfterSeconds, retryAfterSeconds > 0 {
        lines.append("Retrying is safe. Next automatic retry is in about \(retryAfterSeconds)s when this request is part of an attach loop.")
    }
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
        "phase",
        "provider",
        "providerCode",
        "providerMessage",
        "retryable",
        "retryAfterSeconds",
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

private func cloudVMInt(_ value: Any?) -> Int? {
    if let int = value as? Int {
        return int
    }
    if let double = value as? Double, double.isFinite {
        return Int(double)
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String,
       let int = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return int
    }
    return nil
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
    let image: String
    let status: String?
    let createdAt: Int64
    let base: VMBaseSummary?
}

struct VMBaseSummary {
    let id: String
    let name: String
    let generation: Int
    let retainedProviderVmId: String?
}

struct VMExecResult {
    let exitCode: Int
    let stdout: String
    let stderr: String
}

struct VMSnapshotResult {
    let id: String
    let name: String?
    let createdAt: Int64
}

struct VMSSHEndpoint {
    let transport: String
    let host: String
    let port: Int
    let username: String
    let credential: Credential
    let publicKeyFingerprint: String?
    let daemon: VMWebSocketDaemonEndpoint?

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
    let attachmentId: String
    let expiresAtUnix: Int64
    let daemon: VMWebSocketDaemonEndpoint?
}

struct VMCloudSession {
    let id: String
    let vmId: String
    let sessionId: String
    let title: String?
    let kind: String
    let status: String
    let attachmentCount: Int
    let effectiveCols: Int?
    let effectiveRows: Int?
    let lastKnownCols: Int?
    let lastKnownRows: Int?
    let scrollbackBytes: Int
    let metadata: [String: String]
    let createdAt: String
    let updatedAt: String
    let lastAttachedAt: String?
}

struct VMCloudSessionAttach {
    let endpoint: VMAttachEndpoint
    let session: VMCloudSession?
}

struct VMWebSocketDaemonEndpoint {
    let url: String
    let headers: [String: String]
    let token: String
    let sessionId: String
    let expiresAtUnix: Int64
}

/// Per-user subrouter agent-routing state as reported by the backend. The
/// tenant key is a secret; the backend only ever returns it masked.
struct VMAgentRoutingState {
    let configured: Bool
    let subrouterUrl: String?
    let subrouterTenantKeyMasked: String?
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
            let createdAt = (dict["createdAt"] as? Int64)
                ?? Int64((dict["createdAt"] as? Double) ?? 0)
            let status = (dict["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return VMSummary(id: id, provider: provider, image: image, status: status?.isEmpty == false ? status : nil, createdAt: createdAt, base: nil)
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
        let status = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VMSummary(id: id, provider: providerValue, image: imageValue, status: status?.isEmpty == false ? status : nil, createdAt: createdAt, base: nil)
    }

    func openBase(name: String? = nil) async throws -> VMSummary {
        try await baseRequest(path: "/api/vm/base/open", name: name, reason: nil)
    }

    func resetBase(name: String? = nil, reason: String? = nil) async throws -> VMSummary {
        try await baseRequest(path: "/api/vm/base/reset", name: name, reason: reason)
    }

    private func baseRequest(path: String, name: String?, reason: String?) async throws -> VMSummary {
        var body: [String: Any] = [:]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["name"] = name
        }
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["reason"] = reason
        }
        let (data, http) = try await request(
            "POST",
            path: path,
            jsonBody: body,
            timeoutSeconds: Self.createTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let id = obj["id"] as? String,
              let providerValue = obj["provider"] as? String,
              let imageValue = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("Cloud VM Base response was missing required fields.")
        }
        let serverCreatedAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let createdAt = serverCreatedAt > 0 ? serverCreatedAt : Int64(Date().timeIntervalSince1970 * 1000)
        let status = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VMSummary(id: id, provider: providerValue, image: imageValue, status: status?.isEmpty == false ? status : nil, createdAt: createdAt, base: decodeBaseSummary(obj["base"]))
    }

    func status(id: String) async throws -> VMSummary {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request("GET", path: "/api/vm/\(encodedID)")
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let id = obj["id"] as? String,
              let provider = obj["provider"] as? String,
              let image = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("Cloud VM status response was missing required fields.")
        }
        let createdAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let status = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VMSummary(id: id, provider: provider, image: image, status: status?.isEmpty == false ? status : nil, createdAt: createdAt, base: nil)
    }

    func destroy(id: String) async throws {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request("DELETE", path: "/api/vm/\(encodedID)")
        try ensureOK(http, data: data)
    }

    func snapshot(id: String, name: String? = nil) async throws -> VMSnapshotResult {
        var body: [String: Any] = [:]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["name"] = name
        }
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(encodedID)/snapshot",
            jsonBody: body,
            timeoutSeconds: Self.createTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let snapshotID = (obj["snapshotId"] as? String) ?? (obj["id"] as? String),
              !snapshotID.isEmpty
        else {
            throw VMClientError.malformedResponse("Cloud VM snapshot response was missing `snapshotId`.")
        }
        let createdAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let nameValue = obj["name"] as? String
        return VMSnapshotResult(id: snapshotID, name: nameValue, createdAt: createdAt)
    }

    func fork(id: String, name: String? = nil, idempotencyKey: String) async throws -> (snapshot: VMSnapshotResult?, vm: VMSummary) {
        var body: [String: Any] = [:]
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["name"] = name
        }
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(encodedID)/fork",
            jsonBody: body,
            extraHeaders: ["Idempotency-Key": idempotencyKey],
            timeoutSeconds: Self.createTimeoutSeconds * 2
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let vmID = obj["id"] as? String,
              let provider = obj["provider"] as? String,
              let image = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("Cloud VM fork response was missing required fields.")
        }
        let createdAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let status = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshotID = obj["snapshotId"] as? String
        return (
            snapshot: snapshotID.map { VMSnapshotResult(id: $0, name: nil, createdAt: Int64(Date().timeIntervalSince1970 * 1000)) },
            vm: VMSummary(id: vmID, provider: provider, image: image, status: status?.isEmpty == false ? status : nil, createdAt: createdAt, base: nil)
        )
    }

    func restore(snapshotID: String, provider: String? = nil, idempotencyKey: String) async throws -> VMSummary {
        var body: [String: Any] = ["snapshotId": snapshotID]
        if let provider { body["provider"] = provider }
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/restore",
            jsonBody: body,
            extraHeaders: ["Idempotency-Key": idempotencyKey],
            timeoutSeconds: Self.createTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let id = obj["id"] as? String,
              let providerValue = obj["provider"] as? String,
              let image = obj["image"] as? String
        else {
            throw VMClientError.malformedResponse("Cloud VM restore response was missing required fields.")
        }
        let createdAt = (obj["createdAt"] as? Int64)
            ?? Int64((obj["createdAt"] as? Double) ?? 0)
        let status = (obj["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VMSummary(id: id, provider: providerValue, image: image, status: status?.isEmpty == false ? status : nil, createdAt: createdAt, base: nil)
    }

    func openSSH(id: String) async throws -> VMSSHEndpoint {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request("POST", path: "/api/vm/\(encodedID)/ssh-endpoint", jsonBody: [:])
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        return try decodeSSHEndpoint(obj)
    }

    func openAttach(
        id: String,
        requireDaemon: Bool = false,
        sessionId: String? = nil,
        attachmentId: String? = nil,
        title: String? = nil
    ) async throws -> VMAttachEndpoint {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        var body: [String: Any] = ["requireDaemon": requireDaemon]
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["sessionId"] = sessionId
        }
        if let attachmentId, !attachmentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["attachmentId"] = attachmentId
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["title"] = title
        }
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(encodedID)/attach-endpoint",
            jsonBody: body,
            timeoutSeconds: Self.attachTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        return try decodeAttachEndpoint(obj)
    }

    func listSessions(id: String) async throws -> [VMCloudSession] {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        let (data, http) = try await request("GET", path: "/api/vm/\(encodedID)/sessions")
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        let rawSessions = obj["sessions"] as? [[String: Any]] ?? []
        return try rawSessions.map(decodeCloudSession)
    }

    func openSession(
        id: String,
        sessionId: String? = nil,
        attachmentId: String? = nil,
        title: String? = nil
    ) async throws -> VMCloudSessionAttach {
        let encodedID = try pathSegment(id, fieldName: "vm id")
        var body: [String: Any] = [:]
        if let sessionId, !sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["sessionId"] = sessionId
        }
        if let attachmentId, !attachmentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["attachmentId"] = attachmentId
        }
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["title"] = title
        }
        let (data, http) = try await request(
            "POST",
            path: "/api/vm/\(encodedID)/sessions",
            jsonBody: body,
            timeoutSeconds: Self.attachTimeoutSeconds
        )
        try ensureOK(http, data: data)
        let obj = try decodeJSONObject(data)
        guard let endpointObject = obj["endpoint"] as? [String: Any] else {
            throw VMClientError.malformedResponse("Cloud VM session response was missing endpoint.")
        }
        let session = (obj["session"] as? [String: Any]).flatMap { try? decodeCloudSession($0) }
        return VMCloudSessionAttach(endpoint: try decodeAttachEndpoint(endpointObject), session: session)
    }

    private func decodeAttachEndpoint(_ obj: [String: Any]) throws -> VMAttachEndpoint {
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
            let attachmentId = (obj["attachmentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                attachmentId: attachmentId.isEmpty ? UUID().uuidString.lowercased() : attachmentId,
                expiresAtUnix: expiresAtUnix,
                daemon: daemon
            ))
        default:
            throw VMClientError.malformedResponse("Cloud VM attach response used an unsupported transport type.")
        }
    }

    private func decodeBaseSummary(_ raw: Any?) -> VMBaseSummary? {
        guard let obj = raw as? [String: Any] else { return nil }
        guard let id = obj["id"] as? String, !id.isEmpty else { return nil }
        let rawName = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = (obj["generation"] as? Int)
            ?? (obj["generation"] as? NSNumber)?.intValue
            ?? Int((obj["generation"] as? Double) ?? 0)
        let retainedRaw = obj["retainedProviderVmId"]
        let retainedProviderVmId = retainedRaw.flatMap { value in
            cloudVMIsNull(value) ? nil : (value as? String)
        }
        return VMBaseSummary(
            id: id,
            name: rawName?.isEmpty == false ? rawName! : "base",
            generation: generation,
            retainedProviderVmId: retainedProviderVmId
        )
    }

    // MARK: - Agent routing (subrouter)

    func agentRoutingShow() async throws -> VMAgentRoutingState {
        let (data, http) = try await request("GET", path: "/api/vm/agent-routing")
        try ensureOK(http, data: data)
        return try decodeAgentRoutingState(decodeJSONObject(data))
    }

    func agentRoutingSet(url: String, key: String) async throws -> VMAgentRoutingState {
        let body: [String: Any] = ["subrouterUrl": url, "subrouterTenantKey": key]
        let (data, http) = try await request("PUT", path: "/api/vm/agent-routing", jsonBody: body)
        try ensureOK(http, data: data)
        return try decodeAgentRoutingState(decodeJSONObject(data))
    }

    func agentRoutingClear() async throws -> VMAgentRoutingState {
        let (data, http) = try await request("DELETE", path: "/api/vm/agent-routing")
        try ensureOK(http, data: data)
        return try decodeAgentRoutingState(decodeJSONObject(data))
    }

    private func decodeAgentRoutingState(_ obj: [String: Any]) throws -> VMAgentRoutingState {
        guard let configured = obj["configured"] as? Bool else {
            throw VMClientError.malformedResponse("Cloud VM agent routing response was missing `configured`.")
        }
        let url = (obj["subrouterUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let masked = (obj["subrouterTenantKeyMasked"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VMAgentRoutingState(
            configured: configured,
            subrouterUrl: url?.isEmpty == false ? url : nil,
            subrouterTenantKeyMasked: masked?.isEmpty == false ? masked : nil
        )
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

    private func decodeCloudSession(_ obj: [String: Any]) throws -> VMCloudSession {
        guard let id = obj["id"] as? String,
              let vmId = obj["vmId"] as? String,
              let sessionId = obj["sessionId"] as? String,
              let kind = obj["kind"] as? String,
              let status = obj["status"] as? String,
              let createdAt = obj["createdAt"] as? String,
              let updatedAt = obj["updatedAt"] as? String else {
            throw VMClientError.malformedResponse("Cloud VM session response was missing required fields.")
        }
        return VMCloudSession(
            id: id,
            vmId: vmId,
            sessionId: sessionId,
            title: obj["title"] as? String,
            kind: kind,
            status: status,
            attachmentCount: Self.optionalInt(obj["attachmentCount"]) ?? 0,
            effectiveCols: Self.optionalInt(obj["effectiveCols"]),
            effectiveRows: Self.optionalInt(obj["effectiveRows"]),
            lastKnownCols: Self.optionalInt(obj["lastKnownCols"]),
            lastKnownRows: Self.optionalInt(obj["lastKnownRows"]),
            scrollbackBytes: Self.optionalInt(obj["scrollbackBytes"]) ?? 0,
            metadata: Self.stringMetadata(obj["metadata"]),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastAttachedAt: obj["lastAttachedAt"] as? String
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
        let transport = (obj["transport"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedTransport = transport.flatMap { $0.isEmpty ? nil : $0 } ?? "ssh"
        return VMSSHEndpoint(
            transport: normalizedTransport,
            host: host,
            port: port,
            username: username,
            credential: credential,
            publicKeyFingerprint: obj["publicKeyFingerprint"] as? String,
            daemon: try decodeWebSocketDaemonEndpoint(obj["daemon"])
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

    private nonisolated static func optionalInt(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let number = raw as? NSNumber { return number.intValue }
        if let double = raw as? Double { return Int(double) }
        return nil
    }

    private nonisolated static func stringMetadata(_ raw: Any?) -> [String: String] {
        guard let obj = raw as? [String: Any] else { return [:] }
        return obj.reduce(into: [String: String]()) { result, pair in
            switch pair.value {
            case let value as String:
                result[pair.key] = value
            case let value as Bool:
                result[pair.key] = value ? "true" : "false"
            case let value as NSNumber:
                result[pair.key] = value.stringValue
            default:
                break
            }
        }
    }
}
