import Foundation

/// One HTTP exchange; the iOS app supplies a redirect-refusing session.
public protocol InstallAuthTransport: Sendable {
    /// POSTs JSON to `path` (relative to the API Worker) with an optional
    /// bearer. Returns the status and body.
    func post(_ path: String, json: Data, bearer: String?) async throws -> (status: Int, body: Data)
}

/// What the install keeps between launches (never the token).
public struct InstallRecord: Codable, Hashable, Sendable {
    public var user: String
    public var install: String
}

/// The install principal client. Register once per (user, key); every token
/// comes from a fresh challenge (a nonce is never reused). Tokens live only
/// in memory and are never logged.
public actor InstallAuthClient {
    public typealias SessionToken = @Sendable () async throws -> String

    private let transport: any InstallAuthTransport
    private let signer: any InstallSigner
    private let sessionToken: SessionToken
    private let deviceName: String
    private let now: @Sendable () -> Date
    private var record: InstallRecord?
    private var token: (value: String, expiresAt: Date)?
    private var inflight: Task<String, Error>?
    /// Refresh this long before the token expires.
    public static let refreshMargin: TimeInterval = 60

    public init(transport: any InstallAuthTransport, signer: any InstallSigner, sessionToken: @escaping SessionToken,
                deviceName: String, record: InstallRecord?, now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.signer = signer
        self.sessionToken = sessionToken
        self.deviceName = deviceName
        self.record = record
        self.now = now
    }

    /// The registered install (persist it; nil until first registration).
    public var currentRecord: InstallRecord? { record }

    /// A valid install token, minting a new one when needed. Concurrent
    /// callers share one mint.
    public func installToken() async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token.value }
        if let inflight { return try await inflight.value }
        let task = Task { try await self.mint() }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    /// Sign-out or account switch: forget the token and the install binding.
    public func reset() {
        token = nil
        record = nil
    }

    private func mint() async throws -> String {
        let record = try await ensureRegistered()
        let challenge = try await postJSON("/v1/auth/challenge", ["user": record.user, "install": record.install], bearer: nil)
        guard let nonce = challenge["nonce"] as? String, let prefix = challenge["message_prefix"] as? String else {
            throw InstallAuthError.malformedReply
        }
        let signature = try await signer.sign(Data((prefix + nonce).utf8))
        let reply = try await postJSON("/v1/auth/token", ["user": record.user, "install": record.install,
                                                          "nonce": nonce, "signature": Base64URL.encode(signature)], bearer: nil)
        guard let value = reply["access_token"] as? String else { throw InstallAuthError.malformedReply }
        let expiresAt = (reply["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? now().addingTimeInterval(300)
        token = (value, expiresAt)
        return value
    }

    private func ensureRegistered() async throws -> InstallRecord {
        if let record { return record }
        let session = try await sessionToken()
        let user = try await op("user.ensure", params: [:], bearer: session)
        guard let userID = user["id"] as? String else { throw InstallAuthError.malformedReply }
        let jwk = try PublicJWK(x963: try await signer.publicKeyX963())
        let install = try await op("install.register", params: [
            "public_jwk": jwk.json, "kind": "ios", "name": "cmux iOS",
            "device_name": String(deviceName.prefix(80)), "platform": "ios",
        ], bearer: session)
        guard let installID = install["id"] as? String else { throw InstallAuthError.malformedReply }
        let made = InstallRecord(user: userID, install: installID)
        record = made
        return made
    }

    private func op(_ name: String, params: [String: Any], bearer: String) async throws -> [String: Any] {
        let reply = try await postJSON("/v1/ops", ["op": name, "params": params,
                                                   "idempotency_key": "install-" + UUID().uuidString.lowercased(),
                                                   "origin": "cli"], bearer: bearer)
        guard reply["ok"] as? Bool == true else {
            let code = (reply["error"] as? [String: Any])?["code"] as? String ?? "unknown"
            throw InstallAuthError.refused(code)
        }
        guard let value = reply["value"] as? [String: Any] else { throw InstallAuthError.malformedReply }
        return value
    }

    private func postJSON(_ path: String, _ object: [String: Any], bearer: String?) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let (status, data): (Int, Data)
        do { (status, data) = try await transport.post(path, json: body, bearer: bearer) } catch {
            throw InstallAuthError.transport
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw status == 200 ? InstallAuthError.malformedReply : InstallAuthError.refused("http_\(status)")
        }
        guard (200..<300).contains(status) else {
            throw InstallAuthError.refused(reply["code"] as? String ?? "http_\(status)")
        }
        return reply
    }
}
