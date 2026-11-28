public import Foundation

/// The install's P-256 key. The private half never leaves the signer (the
/// Secure Enclave on a device); only the public point and signatures do.
public protocol InstallSigner: Sendable {
    /// Uncompressed public point (X9.63: 0x04 || x || y, 65 bytes).
    func publicKeyX963() async throws -> Data
    /// ES256 over `message` (SHA-256 inside), raw r||s (64 bytes) or DER.
    func sign(_ message: Data) async throws -> Data
    /// Replaces the key (a revoked install, or a key the owner already holds
    /// for another install). The old private key is destroyed.
    func rotate() async throws
}

public enum InstallAuthError: Error, Hashable, Sendable {
    case invalidPublicKey
    case noSession
    case refused(String)
    /// The owner sent a challenge this client will not sign.
    case unexpectedChallenge
    /// `user.ensure` answered for a different Stack user than the session's.
    case userMismatch
    /// The request to `path` got no HTTP answer; `urlErrorCode` is the
    /// transport's `URLError` code when it threw one (-1001: timed out).
    case transport(path: String, urlErrorCode: Int?)
    case malformedReply
    /// The team requires a newer app (`updates.minimumVersion`); the owner
    /// names the minimum. Not an install problem: the key and record stay,
    /// and the same install mints again once the app is updated.
    case clientTooOld(minimumVersion: String?)

    /// The error a `fail` effect of cmux-cloud-config's install_auth names.
    init(failure effect: [String: Any]) {
        switch effect["error"] as? String {
        case "invalid_public_key": self = .invalidPublicKey
        case "no_session": self = .noSession
        case "refused": self = .refused(effect["code"] as? String ?? "unknown")
        case "unexpected_challenge": self = .unexpectedChallenge
        case "user_mismatch": self = .userMismatch
        case "transport":
            self = .transport(path: effect["path"] as? String ?? "", urlErrorCode: (effect["url_error_code"] as? NSNumber)?.intValue)
        case "client_too_old": self = .clientTooOld(minimumVersion: effect["minimum_version"] as? String)
        default: self = .malformedReply
        }
    }
}

/// What a log line or a relay answer says of a failed mint: the step and its code. Never a token.
extension InstallAuthError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidPublicKey: "the install key is not a P-256 point"
        case .noSession: "no sign-in session to register the install with"
        case .refused(let code): "the cmux API refused the install token request (\(code))"
        case .unexpectedChallenge: "the cmux API sent a challenge this install will not sign"
        case .userMismatch: "the cmux API answered for another user"
        case .transport(let path, let code):
            "POST \(path) got no answer" + (code.map { " (URLError \($0))" } ?? "")
        case .malformedReply: "the cmux API answered the install token request with no token"
        case .clientTooOld(let minimum): "this cmux is too old for the team" + (minimum.map { " (needs \($0))" } ?? "")
        }
    }
}

/// The public JWK the owner stores for a key.
public struct PublicJWK: Hashable, Sendable {
    public var x: String
    public var y: String

    public init(x963: Data) throws {
        guard x963.count == 65, x963.first == 0x04 else { throw InstallAuthError.invalidPublicKey }
        x = (x963.subdata(in: 1..<33)).base64URLEncoded
        y = (x963.subdata(in: 33..<65)).base64URLEncoded
    }

    public var json: [String: String] { ["kty": "EC", "crv": "P-256", "x": x, "y": y] }
}

extension Data {
    /// base64url without padding (RFC 4648 section 5).
    public var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One HTTP exchange; the app supplies a redirect-refusing session.
public protocol InstallAuthTransport: Sendable {
    /// POSTs JSON to `path` (relative to the API Worker) with an optional
    /// bearer and extra request `headers` (for example the client version).
    /// Returns the status and body.
    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data)
    /// GETs `path` (relative to the API Worker, query included) with an optional bearer and extra `headers`.
    func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data)
}

extension InstallAuthTransport {
    /// A transport that only posts (the install-auth exchange needs no GET) answers a GET as unsupported.
    public func get(_ path: String, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        throw URLError(.unsupportedURL)
    }
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

    /// The cmux Mac app (cx-wb5.64): the phone grant plus `mutate-shared`
    /// (start, pause and rename team machines through the credential relay);
    /// never `execute`. The server caps a mac register to this set.
    public static let mac = InstallProfile(kind: "mac", name: "cmux", platform: "macos",
                                           opClasses: ["read", "mutate-own", "mutate-shared", "cloud-link"], fallbackDeviceName: "Mac")

    var wire: [String: Any] {
        ["kind": kind, "name": name, "platform": platform, "op_classes": opClasses, "fallback_device_name": fallbackDeviceName]
    }
}

/// The install principal client for one Stack user. Registration needs the
/// user's Stack session; minting a token needs only the record and the key,
/// so a background launch or a sign-out cleanup can still act as the install.
/// Every token comes from a fresh challenge; tokens live only in memory.
///
/// Every rule of the exchange (which request comes next, what each answer must say, which
/// refusals recover, how long a token is trusted) is cmux-cloud-config's `install_auth` step
/// machine, asked over the app FFI (`cloud_identity_install_auth_step`). This actor performs
/// its effects: the HTTP exchange, the signer, the Stack session, the record, and the one
/// shared in-flight mint with its cancellation.
public actor InstallAuthClient {
    public typealias SessionToken = @Sendable () async throws -> String

    private let transport: any InstallAuthTransport
    private let signer: any InstallSigner
    private let sessionToken: SessionToken?
    private let stackUser: String
    /// One immutable requested team per client; its token cache cannot cross scopes.
    private let team: String?
    /// The API's `ENVIRONMENT`, learned from the server (the challenge prefix names it and the
    /// minted token's issuer must agree). A scoped client can pin the one its personal client learned.
    public private(set) var environment: String?
    private let deviceName: String
    private let profile: InstallProfile
    /// This app's version, sent as `x-cmux-client-version`; the owner refuses an older one when
    /// the team sets `updates.minimumVersion` (enterprise P17).
    private let clientVersion: String?
    private let onRecord: (@Sendable (InstallRecord?) async -> Void)?
    private let now: @Sendable () -> Date
    private var record: InstallRecord?
    private var token: (value: String, expiresAt: Date)?
    private var inflight: Task<String, Error>?

    /// Refresh this long before the token expires.
    public static let refreshMargin: TimeInterval = 60
    /// The header the owner's version gate reads (token mint and wire connects).
    public static let clientVersionHeader = "x-cmux-client-version"
    /// The most effects one mint or revoke performs before the client gives up on it.
    static let maximumSteps = 64

    /// - Parameters:
    ///   - team: One backend team id, fixed for this client and its token cache. Nil keeps personal issuance.
    ///   - expectedEnvironment: The environment already verified by the enclosing account client, when available.
    ///   - onRecord: persists the record (Keychain) the moment it changes; nil keeps it in memory only.
    public init(transport: any InstallAuthTransport, signer: any InstallSigner, sessionToken: SessionToken?,
                stackUser: String, deviceName: String, clientVersion: String?, record: InstallRecord?,
                profile: InstallProfile = .mac, team: String? = nil, expectedEnvironment: String? = nil,
                onRecord: (@Sendable (InstallRecord?) async -> Void)? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.transport = transport
        self.signer = signer
        self.sessionToken = sessionToken
        self.stackUser = stackUser
        self.team = team
        self.environment = expectedEnvironment
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
        let task = Task { try await self.mint() }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    /// A valid install token, minted in the caller's own task, so cancelling the caller cancels
    /// the mint's requests. For a client with one caller: nothing is shared with other callers.
    public func installTokenInCallerTask() async throws -> String {
        if let token, token.expiresAt.timeIntervalSince(now()) > Self.refreshMargin { return token.value }
        return try await mint()
    }

    /// L14-2: sign-out revokes this install (needs the Stack session; the
    /// owner also drops the install's push targets). The key is rotated and
    /// the record forgotten, so the next sign-in registers a new install.
    public func revoke() async throws {
        let effect = try await drive(mode: "revoke")
        guard effect["revoked"] as? Bool == true else { return }
        reset()
        self.record = nil
        await onRecord?(nil)
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

    /// The headers every request carries.
    public static func headers(clientVersion: String?) -> [String: String] {
        guard let clientVersion, !clientVersion.isEmpty else { return [:] }
        return [clientVersionHeader: clientVersion]
    }

    private func mint() async throws -> String {
        let effect = try await drive(mode: "mint")
        guard let value = effect["token"] as? String, let named = effect["environment"] as? String,
              let expiresAt = (effect["expires_at_ms"] as? NSNumber)?.doubleValue else {
            throw InstallAuthError.malformedReply
        }
        // A mint cancelled by reset() (sign-out) must not store its token.
        try Task.checkCancellation()
        environment = named
        token = (value, Date(timeIntervalSince1970: expiresAt / 1000))
        return value
    }

    /// Runs the step machine from its start to `done` or `revoked`, performing each effect.
    private func drive(mode: String) async throws -> [String: Any] {
        var state: Any = NSNull()
        var event: [String: Any] = [
            "event": "start", "mode": mode, "stack_user": stackUser, "team": team ?? NSNull(),
            "environment": environment ?? NSNull(), "device_name": deviceName, "profile": profile.wire,
            "client_version": clientVersion ?? NSNull(),
            "record": record.map { ["user": $0.user, "install": $0.install] as Any } ?? NSNull(),
            "has_session": sessionToken != nil,
            "fresh_ids": [UUID().uuidString.lowercased(), UUID().uuidString.lowercased()],
        ]
        // The machine ends every exchange in a few dozen steps (the longest mint registers, rotates,
        // registers again, recovers once and mints again); past the bound it is answering in a circle.
        for _ in 0..<Self.maximumSteps {
            let effect: [String: Any]
            (state, effect) = try step(state, event)
            switch effect["effect"] as? String {
            case "session_token":
                guard let sessionToken else { throw InstallAuthError.noSession }
                event = ["event": "session", "token": try await sessionToken()]
            case "public_key":
                event = ["event": "public_key", "x963": try await signer.publicKeyX963().base64EncodedString()]
            case "sign":
                let message = Data((effect["message"] as? String ?? "").utf8)
                event = ["event": "signature", "signature": try await signer.sign(message).base64EncodedString()]
            case "rotate":
                try await signer.rotate()
                event = ["event": "rotated"]
            case "post":
                event = await post(effect)
            case "save_record":
                let saved = effect["record"] as? [String: Any]
                record = (saved?["user"] as? String).flatMap { user in
                    (saved?["install"] as? String).map { InstallRecord(user: user, install: $0) }
                }
                await onRecord?(record)
                event = ["event": "saved"]
            case "done", "revoked":
                return effect
            case "fail":
                throw InstallAuthError(failure: effect)
            default:
                throw InstallAuthError.malformedReply
            }
        }
        throw InstallAuthError.malformedReply
    }

    private func post(_ effect: [String: Any]) async -> [String: Any] {
        let path = effect["path"] as? String ?? ""
        do {
            let (status, data) = try await transport.post(
                path, json: Data((effect["body"] as? String ?? "").utf8), bearer: effect["bearer"] as? String,
                headers: effect["headers"] as? [String: String] ?? [:])
            return ["event": "http", "status": status, "body": String(decoding: data, as: UTF8.self)]
        } catch {
            return ["event": "transport_error", "url_error_code": (error as? URLError)?.code.rawValue ?? NSNull()]
        }
    }

    /// One step of cmux-cloud-config's install_auth; an FFI that does not answer fails closed.
    private func step(_ state: Any, _ event: [String: Any]) throws -> (Any, [String: Any]) {
        let request: [String: Any] = ["state": state, "event": event, "now_ms": now().timeIntervalSince1970 * 1000]
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let answer = CloudStartCore().callData("cloud_identity_install_auth_step", data),
              let reply = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let effect = reply["effect"] as? [String: Any] else { throw InstallAuthError.malformedReply }
        return (reply["state"] ?? NSNull(), effect)
    }
}
