import CryptoKit
import Foundation
import IrohLib

/// How the broker client authenticates to the cmux web API.
public enum PtxBrokerAuth: Sendable {
    /// Stack password sign-in (dev profiles from ~/.secrets).
    case password(
        stackBase: String, projectID: String, publishableClientKey: String,
        email: String, password: String)
    /// Live app session: returns (accessToken, refreshToken) per request.
    case tokens(@Sendable () async throws -> (access: String, refresh: String))
}

public struct PtxRelayCredential: Sendable, Equatable, Codable {
    public var relayURL: String
    public var token: String
    public var expiresAt: Int64?

    public init(relayURL: String, token: String, expiresAt: Int64?) {
        self.relayURL = relayURL
        self.token = token
        self.expiresAt = expiresAt
    }
}

public enum PtxBrokerError: Error, CustomStringConvertible {
    case http(step: String, status: Int, body: String)
    case shape(String)

    public var description: String {
        switch self {
        case .http(let step, let status, let body):
            return "\(step): HTTP \(status) \(body.prefix(200))"
        case .shape(let what):
            return "unexpected response shape: \(what)"
        }
    }
}

/// Mints endpoint-bound relay credentials from the cmux trust broker:
/// challenge → Ed25519 proof over the registration transcript → register
/// (endpoint_already_bound = success) → token catalog. Both sides self-mint
/// with their own identity; nothing depends on a live session to deliver
/// credentials (the delivery dependencies are what failed in the field).
public struct PtxBrokerClient: Sendable {
    public var baseURL: String
    public var auth: PtxBrokerAuth
    public var identity: PtxIdentity
    public var appInstanceID: String
    public var tag: String
    public var platform: String

    public init(
        baseURL: String, auth: PtxBrokerAuth, identity: PtxIdentity,
        appInstanceID: String, tag: String, platform: String
    ) {
        self.baseURL = baseURL
        self.auth = auth
        self.identity = identity
        self.appInstanceID = appInstanceID
        self.tag = tag
        self.platform = platform
    }

    /// Registers (idempotently) and mints one credential per fleet relay.
    public func registerAndMint() async throws -> [PtxRelayCredential] {
        let endpointID = identity.endpointIDHex
        let authed = try await authHeaders()

        let payload: PtxJSON = .object([
            "route_contract_version": .int(1),
            "deviceId": .string(identity.deviceID),
            "appInstanceId": .string(appInstanceID),
            "tag": .string(tag),
            "platform": .string(platform),
            "endpointId": .string(endpointID),
            "identityGeneration": .int(1),
            "pairingEnabled": .bool(false),
            "capabilities": .array([.string("cmux.ptx")]),
            "pathHints": .array([]),
        ])
        let payloadBytes = try JSONEncoder().encode(payload)
        let payloadB64 = Self.base64url(payloadBytes)
        let payloadSha = SHA256.hash(data: payloadBytes)
            .map { String(format: "%02x", $0) }.joined()

        let challenge = try await post(
            "\(baseURL)/api/devices/iroh/challenge", headers: authed,
            body: [
                "deviceId": .string(identity.deviceID),
                "appInstanceId": .string(appInstanceID),
                "tag": .string(tag),
                "endpointId": .string(endpointID),
                "identityGeneration": .int(1),
                "payloadSha256": .string(payloadSha),
            ], step: "broker-challenge")
        guard let challengeID = challenge["challenge_id"]?.stringValue,
            let nonce = challenge["nonce"]?.stringValue
        else { throw PtxBrokerError.shape("challenge fields") }

        let transcript = Data(
            "cmux/iroh/device-registration/v1\n\(challengeID)\n\(nonce)\n\(payloadSha)".utf8)
        let signature = Self.base64url(try identity.sign(transcript))

        var registered: [String: PtxJSON] = [:]
        do {
            registered = try await post(
                "\(baseURL)/api/devices/iroh/register", headers: authed,
                body: [
                    "challengeId": .string(challengeID),
                    "nonce": .string(nonce),
                    "payload": .string(payloadB64),
                    "signature": .string(signature),
                ], step: "broker-register")
        } catch let error as PtxBrokerError {
            guard case .http(_, _, let body) = error, body.contains("endpoint_already_bound")
            else { throw error }
        }

        if registered["relay"]?.objectValue?["status"]?.stringValue == "issued",
            let token = registered["relay"]?.objectValue?["token"]?.stringValue
        {
            let relays =
                registered["relay"]?.objectValue?["relay_fleet"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            if !relays.isEmpty {
                return relays.map {
                    PtxRelayCredential(
                        relayURL: $0, token: token,
                        expiresAt: PtxEndpoint.tokenExpiry(token))
                }
            }
        }
        return try await mintTokens(headers: authed, endpointID: endpointID)
    }

    /// Steady-state renewal: one POST, no registration legs.
    public func mint() async throws -> [PtxRelayCredential] {
        try await mintTokens(headers: try await authHeaders(), endpointID: identity.endpointIDHex)
    }

    private func mintTokens(
        headers: [String: String], endpointID: String
    ) async throws -> [PtxRelayCredential] {
        let minted = try await post(
            "\(baseURL)/api/relay/token", headers: headers,
            body: ["endpointId": .string(endpointID)], step: "relay-token")
        var credentials: [PtxRelayCredential] = []
        if let list = minted["relayCredentials"]?.arrayValue {
            credentials = list.compactMap { entry in
                guard let object = entry.objectValue,
                    let url = object["relayUrl"]?.stringValue,
                    let token = object["token"]?.stringValue
                else { return nil }
                return PtxRelayCredential(
                    relayURL: url, token: token, expiresAt: object["expiresAt"]?.intValue)
            }
        } else if let token = minted["token"]?.stringValue {
            let relays = minted["relays"]?.arrayValue?.compactMap(\.stringValue) ?? []
            credentials = relays.map {
                PtxRelayCredential(
                    relayURL: $0, token: token, expiresAt: minted["expiresAt"]?.intValue)
            }
        }
        guard !credentials.isEmpty else {
            throw PtxBrokerError.shape("no credentials issued (unbound endpoint?)")
        }
        return credentials
    }

    private func authHeaders() async throws -> [String: String] {
        switch auth {
        case .password(let stackBase, let projectID, let pck, let email, let password):
            let signIn = try await post(
                "\(stackBase)/api/v1/auth/password/sign-in",
                headers: [
                    "content-type": "application/json",
                    "x-stack-project-id": projectID,
                    "x-stack-publishable-client-key": pck,
                    "x-stack-access-type": "client",
                ],
                body: ["email": .string(email), "password": .string(password)],
                step: "stack-sign-in")
            guard let access = signIn["access_token"]?.stringValue,
                let refresh = signIn["refresh_token"]?.stringValue
            else { throw PtxBrokerError.shape("sign-in tokens") }
            return [
                "content-type": "application/json",
                "authorization": "Bearer \(access)",
                "x-stack-refresh-token": refresh,
            ]
        case .tokens(let provider):
            let (access, refresh) = try await provider()
            return [
                "content-type": "application/json",
                "authorization": "Bearer \(access)",
                "x-stack-refresh-token": refresh,
            ]
        }
    }

    private func post(
        _ url: String, headers: [String: String], body: [String: PtxJSON], step: String
    ) async throws -> [String: PtxJSON] {
        guard let requestURL = URL(string: url) else {
            throw PtxBrokerError.shape("bad URL \(url)")
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(PtxJSON.object(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PtxBrokerError.http(
                step: step, status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONDecoder().decode(PtxJSON.self, from: data))?.objectValue ?? [:]
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Owns one endpoint's relay credentials: persisted cache for instant boot,
/// single-flight refresh, a renew loop that rotates in-place (insertRelay
/// alone, zero-gap), and offline introspection so a wrong-key or expired
/// token is named BEFORE a dial instead of dying silently at the relay.
public actor PtxCredentialService {
    private let broker: PtxBrokerClient
    private let defaults: UserDefaults
    private let cacheKey: String
    private let log: PtxEventLog
    /// Renew this many seconds before expiry (tokens live 300s, refreshAfter
    /// is expiry-60; renewing at expiry-70 keeps one retry inside validity).
    private let renewLead: Int64 = 70

    private var cached: [PtxRelayCredential] = []
    private var refreshTask: Task<[PtxRelayCredential], any Error>?
    private var renewLoop: Task<Void, Never>?
    private var registeredOnce: Bool

    public init(
        broker: PtxBrokerClient, defaults: UserDefaults, cacheKey: String, log: PtxEventLog
    ) {
        self.broker = broker
        self.defaults = defaults
        self.cacheKey = cacheKey
        self.log = log
        self.registeredOnce = defaults.bool(forKey: cacheKey + ".registered")
        if let data = defaults.data(forKey: cacheKey),
            let stored = try? JSONDecoder().decode([PtxRelayCredential].self, from: data)
        {
            self.cached = stored
        }
    }

    /// Instant, offline: cached credentials still valid for >30s and bound to
    /// OUR key. Used to boot the endpoint with no network on the fast path.
    public func validCachedCredentials(now: Date = Date()) -> [PtxRelayCredential] {
        let floor = Int64(now.timeIntervalSince1970) + 30
        let valid = cached.filter { credential in
            guard let expiry = credential.expiresAt ?? PtxEndpoint.tokenExpiry(credential.token),
                expiry > floor
            else { return false }
            return PtxEndpoint.tokenEndpointID(credential.token) == broker.identity.publicKeyData
        }
        if !valid.isEmpty {
            log.emit(
                PtxEventKind.credentialCached,
                detail: ["count": String(valid.count), "relay": valid[0].relayURL])
        }
        return valid
    }

    /// Fresh credentials, single-flight. First-ever call runs the full
    /// register leg; steady state is one POST.
    public func freshCredentials() async throws -> [PtxRelayCredential] {
        if let refreshTask {
            return try await refreshTask.value
        }
        let start = ContinuousClock.now
        let needsRegister = !registeredOnce
        let task = Task<[PtxRelayCredential], any Error> { [broker] in
            if needsRegister {
                return try await broker.registerAndMint()
            }
            do {
                return try await broker.mint()
            } catch PtxBrokerError.shape {
                // Policy-only response: the endpoint is not bound under the
                // CALLING account (registry-side unbinding, or the token
                // source now serves a different account). One re-register
                // heals the binding; a genuine failure throws from there.
                return try await broker.registerAndMint()
            }
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let minted = try await task.value
            registeredOnce = true
            cached = minted
            defaults.set(true, forKey: cacheKey + ".registered")
            if let data = try? JSONEncoder().encode(minted) {
                defaults.set(data, forKey: cacheKey)
            }
            log.emit(
                PtxEventKind.credentialMinted, ms: log.elapsedMs(since: start),
                detail: [
                    "count": String(minted.count),
                    "registered": needsRegister ? "1" : "0",
                    "expiresAt": minted.first?.expiresAt.map(String.init) ?? "-",
                ])
            return minted
        } catch {
            log.emit(
                PtxEventKind.credentialError, reason: "mint-failed",
                ms: log.elapsedMs(since: start),
                detail: ["error": String(describing: error)])
            throw error
        }
    }

    /// Valid cache or a fresh mint — the pre-dial guarantee.
    public func currentCredentials() async throws -> [PtxRelayCredential] {
        let valid = validCachedCredentials()
        if !valid.isEmpty { return valid }
        return try await freshCredentials()
    }

    /// Runs for the endpoint's lifetime: renews ahead of expiry and rotates
    /// the fresh token into the LIVE endpoint. Never removes a relay.
    public func startRenewLoop(endpoint: sending IrohEndpointBox, preferredRelayURL: String?) {
        renewLoop?.cancel()
        renewLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sleepSeconds = await self.secondsUntilRenewal()
                // Floor of 30s: when credentials are stale or minting keeps
                // failing, retrying faster only burns the broker rate budget.
                try? await Task.sleep(for: .seconds(max(30, sleepSeconds)))
                guard !Task.isCancelled else { return }
                await self.renewAndRotate(endpoint: endpoint, preferredRelayURL: preferredRelayURL)
            }
        }
    }

    public func stopRenewLoop() {
        renewLoop?.cancel()
        renewLoop = nil
    }

    private func secondsUntilRenewal(now: Date = Date()) -> Int64 {
        guard
            let expiry = cached.compactMap({
                $0.expiresAt ?? PtxEndpoint.tokenExpiry($0.token)
            }).min()
        else { return 10 }
        return expiry - renewLead - Int64(now.timeIntervalSince1970)
    }

    private func renewAndRotate(endpoint: IrohEndpointBox, preferredRelayURL: String?) async {
        do {
            let minted = try await freshCredentials()
            let ordered = Self.preferring(minted, url: preferredRelayURL)
            guard let primary = ordered.first else { return }
            _ = await PtxEndpoint.rotateRelay(
                endpoint: endpoint.endpoint, url: primary.relayURL, token: primary.token,
                log: log)
        } catch {
            // freshCredentials already logged; the loop will retry on the
            // next tick (secondsUntilRenewal floors at 5s when stale).
        }
    }

    public static func preferring(
        _ credentials: [PtxRelayCredential], url: String?
    ) -> [PtxRelayCredential] {
        guard let url, let index = credentials.firstIndex(where: { $0.relayURL == url }) else {
            return credentials
        }
        var ordered = credentials
        ordered.swapAt(0, index)
        return ordered
    }
}

/// Sendable wrapper for the FFI endpoint handle (the generated class is
/// @unchecked Sendable in iroh-ffi; the box keeps our API surface explicit).
public struct IrohEndpointBox: Sendable {
    public let endpoint: IrohLib.Endpoint

    public init(endpoint: IrohLib.Endpoint) {
        self.endpoint = endpoint
    }
}
