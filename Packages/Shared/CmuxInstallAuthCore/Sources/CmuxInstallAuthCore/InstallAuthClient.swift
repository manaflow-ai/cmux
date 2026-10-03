import CryptoKit
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

    public init(user: String, install: String) {
        self.user = user
        self.install = install
    }
}

/// The install principal client for one Stack user. Registration needs the
/// user's Stack session; minting a token needs only the record and the key,
/// so a background launch or a sign-out cleanup can still act as the install.
/// Every token comes from a fresh challenge; tokens live only in memory.
public actor InstallAuthClient {
    public typealias SessionToken = @Sendable () async throws -> String

    private let transport: any InstallAuthTransport
    private let signer: any InstallSigner
    private let sessionToken: SessionToken?
    private let stackUser: String
    private let environment: String
    private let deviceName: String
    private let onRecord: @Sendable (InstallRecord?) async -> Void
    private let now: @Sendable () -> Date
    private var record: InstallRecord?
    private var token: (value: String, expiresAt: Date)?
    private var inflight: Task<String, Error>?

    /// Refresh this long before the token expires.
    public static let refreshMargin: TimeInterval = 60
    /// Never trust a token longer than this (device clock skew).
    public static let maximumLifetime: TimeInterval = 540

    /// - Parameters:
    ///   - environment: the API's `ENVIRONMENT` (`staging`, `production`); the
    ///     challenge prefix must name it.
    ///   - onRecord: persists the record (Keychain) the moment it changes.
    public init(transport: any InstallAuthTransport, signer: any InstallSigner, sessionToken: SessionToken?,
                stackUser: String, environment: String, deviceName: String, record: InstallRecord?,
                onRecord: @escaping @Sendable (InstallRecord?) async -> Void = { _ in },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.signer = signer
        self.sessionToken = sessionToken
        self.stackUser = stackUser
        self.environment = environment
        self.deviceName = deviceName
        self.record = record
        self.onRecord = onRecord
        self.now = now
    }

    public var currentRecord: InstallRecord? { record }

    /// A valid install token, minting a new one when needed. Concurrent
    /// callers share one mint.
    public func installToken() async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token.value }
        if let inflight { return try await inflight.value }
        let task = Task { try await self.mintRecovering() }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    /// The owner refused the current token (401): mint a new one next time.
    public func invalidate() { token = nil }

    /// Sign-out: forget the token (the record stays for cleanup ops).
    public func reset() {
        inflight?.cancel()
        inflight = nil
        token = nil
    }

    /// A revoked or unknown install is registered again with a new key, once.
    private func mintRecovering() async throws -> String {
        do {
            return try await mint()
        } catch InstallAuthError.refused(let code) where code == "auth.forbidden" {
            try await signer.rotate()
            record = nil
            await onRecord(nil)
            return try await mint()
        }
    }

    private func mint() async throws -> String {
        let record = try await ensureRegistered()
        let challenge = try await postJSON("/v1/auth/challenge", ["user": record.user, "install": record.install], bearer: nil)
        guard let nonce = challenge["nonce"] as? String, let prefix = challenge["message_prefix"] as? String,
              prefix == "cmux-auth-v1\n\(environment)\n\(record.install)\n", Self.isNonce(nonce) else {
            throw InstallAuthError.unexpectedChallenge
        }
        let signature = try await signer.sign(Data((prefix + nonce).utf8))
        let reply = try await postJSON("/v1/auth/token", ["user": record.user, "install": record.install,
                                                          "nonce": nonce, "signature": (signature).base64URLEncoded], bearer: nil)
        guard let value = reply["access_token"] as? String else { throw InstallAuthError.malformedReply }
        let cap = now().addingTimeInterval(Self.maximumLifetime)
        let stated = (reply["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? cap
        token = (value, min(stated, cap))
        return value
    }

    static func isNonce(_ value: String) -> Bool {
        (16...128).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    private func ensureRegistered() async throws -> InstallRecord {
        if let record { return record }
        guard let sessionToken else { throw InstallAuthError.noSession }
        let session = try await sessionToken()
        let user = try await op("user.ensure", params: [:], key: "user-ensure-" + UUID().uuidString.lowercased(), bearer: session)
        guard let userID = user["id"] as? String else { throw InstallAuthError.malformedReply }
        guard user["stack_user_id"] as? String == stackUser else { throw InstallAuthError.userMismatch }
        var attempts = 0
        while true {
            attempts += 1
            let x963 = try await signer.publicKeyX963()
            let jwk = try PublicJWK(x963: x963)
            let thumbprint = SHA256.hash(data: x963).prefix(16).map { String(format: "%02x", $0) }.joined()
            do {
                // Keyed by (user, key): a lost reply is replayed, never a second install.
                let install = try await op("install.register", params: [
                    "public_jwk": jwk.json, "kind": "ios", "name": "cmux iOS",
                    "device_name": Self.displayName(deviceName), "platform": "ios",
                ], key: "install-register-\(userID)-\(thumbprint)", bearer: session)
                guard let installID = install["id"] as? String else { throw InstallAuthError.malformedReply }
                let made = InstallRecord(user: userID, install: installID)
                record = made
                await onRecord(made)
                return made
            } catch InstallAuthError.refused(let code) where code == "key.already_registered" && attempts == 1 {
                // The owner holds this key for an install whose record was lost
                // (a reinstall): start over with a new key.
                try await signer.rotate()
            }
        }
    }

    /// 1 to 80 UTF-16 units (the owner's display-name limit).
    static func displayName(_ name: String) -> String {
        var result = ""
        for character in name {
            if result.utf16.count + String(character).utf16.count > 80 { break }
            result.append(character)
        }
        return result.isEmpty ? "iPhone" : result
    }

    private func op(_ name: String, params: [String: Any], key: String, bearer: String) async throws -> [String: Any] {
        let reply = try await postJSON("/v1/ops", ["op": name, "params": params, "idempotency_key": key, "origin": "cli"], bearer: bearer)
        guard reply["ok"] as? Bool == true else {
            let error = reply["error"] as? [String: Any]
            let message = error?["message"] as? String ?? ""
            if message.contains("already registered") { throw InstallAuthError.refused("key.already_registered") }
            throw InstallAuthError.refused(error?["code"] as? String ?? "unknown")
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
