import CryptoKit
import Foundation

/// One HTTP exchange; the iOS app supplies a redirect-refusing session.
public protocol InstallAuthTransport: Sendable {
    /// POSTs JSON to `path` (relative to the API Worker) with an optional
    /// bearer and extra request `headers` (for example the client version).
    /// Returns the status and body.
    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data)
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

/// What an install registers as: its kind, display name, platform and the
/// op classes it asks for (the backend's default for the kind, which a
/// register may narrow but never widen; user.ts defaultInstallClasses).
public struct InstallProfile: Hashable, Sendable {
    public var kind: String
    public var name: String
    public var platform: String
    public var opClasses: [String]
    /// The device name when the system gives none.
    public var fallbackDeviceName: String

    public init(kind: String, name: String, platform: String, opClasses: [String], fallbackDeviceName: String) {
        self.kind = kind
        self.name = name
        self.platform = platform
        self.opClasses = opClasses
        self.fallbackDeviceName = fallbackDeviceName
    }

    /// The iPhone app. L14-1: never `execute` (no terminal input, code or
    /// CUA acts from a stolen phone token); `cloud-link` lets it mint Cloud
    /// link tokens.
    public static let ios = InstallProfile(kind: "ios", name: "cmux iOS", platform: "ios",
                                           opClasses: ["read", "mutate-own", "cloud-link"], fallbackDeviceName: "iPhone")
    /// The cmux Mac app (cx-wb5.64): the phone grant plus `mutate-shared`
    /// (start, pause and rename team machines through the credential relay);
    /// never `execute`. The server caps a mac register to this set.
    public static let mac = InstallProfile(kind: "mac", name: "cmux", platform: "macos",
                                           opClasses: ["read", "mutate-own", "mutate-shared", "cloud-link"], fallbackDeviceName: "Mac")
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
    /// The API's `ENVIRONMENT` (`staging`, `production`, `development`,
    /// `local`), learned from the server: the challenge prefix names it and
    /// the minted token's issuer (`https://cmux-api/<environment>`) must
    /// agree. Never derived from the host name. Nil before the first mint.
    /// The issuer check is a consistency check (the token signature is the
    /// owner's to verify); trust comes from TLS and the per-host install key.
    public private(set) var environment: String?
    private let deviceName: String
    private let profile: InstallProfile
    /// This app's version (`CFBundleShortVersionString`), sent as
    /// `x-cmux-client-version`; the owner refuses an older one when the team
    /// sets `updates.minimumVersion` (enterprise P17).
    private let clientVersion: String?
    private let onRecord: @Sendable (InstallRecord?) async -> Void
    private let now: @Sendable () -> Date
    private var record: InstallRecord?
    private var token: (value: String, expiresAt: Date)?
    private var inflight: Task<String, Error>?

    /// Refresh this long before the token expires.
    public static let refreshMargin: TimeInterval = 60
    /// Never trust a token longer than this (device clock skew).
    public static let maximumLifetime: TimeInterval = 540
    /// The header the owner's version gate reads (token mint and wire connects).
    public static let clientVersionHeader = "x-cmux-client-version"

    /// - Parameters:
    ///   - onRecord: persists the record (Keychain) the moment it changes.
    public init(transport: any InstallAuthTransport, signer: any InstallSigner, sessionToken: SessionToken?,
                stackUser: String, deviceName: String, clientVersion: String?, record: InstallRecord?,
                profile: InstallProfile = .ios,
                onRecord: @escaping @Sendable (InstallRecord?) async -> Void = { _ in },
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.signer = signer
        self.sessionToken = sessionToken
        self.stackUser = stackUser
        self.deviceName = deviceName
        self.profile = profile
        self.clientVersion = clientVersion
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

    /// The op classes the phone's install asks for (``InstallProfile/ios``).
    public static let grantClasses = InstallProfile.ios.opClasses

    /// L14-2: sign-out revokes this install (needs the Stack session; the
    /// owner also drops the install's push targets). The key is rotated and
    /// the record forgotten, so the next sign-in registers a new install.
    public func revoke() async throws {
        guard let record else { return }
        guard let sessionToken else { throw InstallAuthError.noSession }
        let session = try await sessionToken()
        _ = try await op("install.revoke", params: ["install": record.install],
                         key: "install-revoke-\(record.install)", bearer: session)
        reset()
        self.record = nil
        await onRecord(nil)
        try await signer.rotate()
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
              let named = Self.environment(inPrefix: prefix, install: record.install), Self.isNonce(nonce) else {
            throw InstallAuthError.unexpectedChallenge
        }
        // Once learned, the environment never changes for this client.
        if let environment, environment != named { throw InstallAuthError.unexpectedChallenge }
        let signature = try await signer.sign(Data((prefix + nonce).utf8))
        let reply = try await postJSON("/v1/auth/token", ["user": record.user, "install": record.install,
                                                          "nonce": nonce, "signature": (signature).base64URLEncoded], bearer: nil)
        guard let value = reply["access_token"] as? String else { throw InstallAuthError.malformedReply }
        guard Self.issuer(of: value) == "https://cmux-api/\(named)" else { throw InstallAuthError.unexpectedChallenge }
        // A mint cancelled by reset() (sign-out) must not store its token.
        try Task.checkCancellation()
        environment = named
        let cap = now().addingTimeInterval(Self.maximumLifetime)
        let stated = (reply["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? cap
        token = (value, min(stated, cap))
        return value
    }

    /// The environment in `cmux-auth-v1\n<environment>\n<install>\n`, or nil
    /// when the prefix has any other shape.
    static func environment(inPrefix prefix: String, install: String) -> String? {
        let head = "cmux-auth-v1\n", tail = "\n\(install)\n"
        guard prefix.hasPrefix(head), prefix.hasSuffix(tail), prefix.count > head.count + tail.count else { return nil }
        let name = String(prefix.dropFirst(head.count).dropLast(tail.count))
        guard name.count <= 32, let first = name.first, first.isASCII, first.isLowercase,
              name.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }) else { return nil }
        return name
    }

    /// The `iss` claim of a JWT (payload read only; the owner verifies it).
    static func issuer(of token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Data(base64URLEncoded: String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return claims["iss"] as? String
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
                    "public_jwk": jwk.json, "kind": profile.kind, "name": profile.name,
                    "device_name": Self.displayName(deviceName, fallback: profile.fallbackDeviceName),
                    "platform": profile.platform,
                    // Never `execute` for ios or mac (InstallProfile).
                    "op_classes": profile.opClasses,
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
    static func displayName(_ name: String, fallback: String = "iPhone") -> String {
        var result = ""
        for character in name {
            if result.utf16.count + String(character).utf16.count > 80 { break }
            result.append(character)
        }
        return result.isEmpty ? fallback : result
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

    /// The headers every request carries.
    public static func headers(clientVersion: String?) -> [String: String] {
        guard let clientVersion, !clientVersion.isEmpty else { return [:] }
        return [clientVersionHeader: clientVersion]
    }

    private func postJSON(_ path: String, _ object: [String: Any], bearer: String?) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let (status, data): (Int, Data)
        do {
            (status, data) = try await transport.post(path, json: body, bearer: bearer,
                                                      headers: Self.headers(clientVersion: clientVersion))
        } catch {
            throw InstallAuthError.transport
        }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw status == 200 ? InstallAuthError.malformedReply : InstallAuthError.refused("http_\(status)")
        }
        guard (200..<300).contains(status) else {
            let code = reply["code"] as? String
            if code == "client.too_old" {
                throw InstallAuthError.clientTooOld(minimumVersion: reply["minimum_version"] as? String)
            }
            throw InstallAuthError.refused(code ?? "http_\(status)")
        }
        return reply
    }
}
