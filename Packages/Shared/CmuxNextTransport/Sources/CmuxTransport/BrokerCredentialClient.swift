import CryptoKit
import Foundation

/// The phone mints its OWN relay credentials over HTTPS, exactly as the
/// production app will (contract 9.6/9.7): sign in, prove key ownership to
/// the trust broker, fetch endpoint-bound fleet tokens. This removes every
/// external delivery dependency that failed in the field: ctl pushes need a
/// live session, devicectl relaunches need a reachable phone — but a device
/// that can reach the internet can always fetch its own pass.
///
/// Mirrors iroh-testbed/tools/get-relay-token.mjs step for step.
public struct BrokerCredentialClient: Sendable {
    public struct Config: Sendable, Decodable {
        public var baseUrl: String
        public var stackBase: String
        public var stackProjectId: String
        public var stackPck: String
        public var email: String
        public var password: String
        public var deviceId: String
        public var appInstanceId: String
        public var tag: String
        public var platform: String
    }

    public struct Credential: Sendable {
        public let relayUrl: String
        public let token: String
        public let expiresAt: Int64?
    }

    public enum BrokerError: Error, CustomStringConvertible {
        case http(String, Int, String)
        case shape(String)

        public var description: String {
            switch self {
            case .http(let step, let code, let body):
                return "\(step) failed: HTTP \(code) \(body.prefix(200))"
            case .shape(let what):
                return "unexpected response shape: \(what)"
            }
        }
    }

    private let config: Config
    private let identity: PeerIdentity

    public init(config: Config, identity: PeerIdentity) {
        self.config = config
        self.identity = identity
    }

    /// Full mint: returns one credential per fleet relay; `preferredUrl`
    /// (the rendezvous relay from the ticket) is first when present.
    public func mint(preferredUrl: String?) async throws -> [Credential] {
        let endpointId = identity.publicKeyData.map { String(format: "%02x", $0) }.joined()

        // 1. Stack password sign-in.
        let signIn = try await post(
            "\(config.stackBase)/api/v1/auth/password/sign-in",
            headers: [
                "content-type": "application/json",
                "x-stack-project-id": config.stackProjectId,
                "x-stack-publishable-client-key": config.stackPck,
                "x-stack-access-type": "client",
            ],
            body: ["email": .string(config.email), "password": .string(config.password)],
            step: "stack sign-in")
        guard let access = signIn["access_token"]?.stringValue,
            let refresh = signIn["refresh_token"]?.stringValue
        else { throw BrokerError.shape("sign-in tokens") }
        let authed = [
            "content-type": "application/json",
            "authorization": "Bearer \(access)",
            "x-stack-refresh-token": refresh,
        ]

        // 2. Registration payload; hash OUR exact bytes.
        let payload: JSONValue = .object([
            "route_contract_version": .int(1),
            "deviceId": .string(config.deviceId),
            "appInstanceId": .string(config.appInstanceId),
            "tag": .string(config.tag),
            "platform": .string(config.platform),
            "endpointId": .string(endpointId),
            "identityGeneration": .int(1),
            "pairingEnabled": .bool(false),
            "capabilities": .array([.string("cmux.testbed")]),
            "pathHints": .array([]),
        ])
        let payloadBytes = try JSONEncoder().encode(payload)
        let payloadB64 = base64url(payloadBytes)
        let payloadSha = SHA256.hash(data: payloadBytes)
            .map { String(format: "%02x", $0) }.joined()

        // 3. Challenge.
        let challenge = try await post(
            "\(config.baseUrl)/api/devices/iroh/challenge", headers: authed,
            body: [
                "deviceId": .string(config.deviceId),
                "appInstanceId": .string(config.appInstanceId),
                "tag": .string(config.tag),
                "endpointId": .string(endpointId),
                "identityGeneration": .int(1),
                "payloadSha256": .string(payloadSha),
            ], step: "broker challenge")
        guard let challengeId = challenge["challenge_id"]?.stringValue,
            let nonce = challenge["nonce"]?.stringValue
        else { throw BrokerError.shape("challenge fields") }

        // 4. Sign the transcript with the endpoint's own key.
        let transcript = Data(
            "cmux/iroh/device-registration/v1\n\(challengeId)\n\(nonce)\n\(payloadSha)".utf8)
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: identity.privateKeyData)
        let signature = base64url(try key.signature(for: transcript))

        // 5. Register; an endpoint already bound to this account is success.
        var registered: [String: JSONValue] = [:]
        do {
            registered = try await post(
                "\(config.baseUrl)/api/devices/iroh/register", headers: authed,
                body: [
                    "challengeId": .string(challengeId),
                    "nonce": .string(nonce),
                    "payload": .string(payloadB64),
                    "signature": .string(signature),
                ], step: "broker register")
        } catch let error as BrokerError {
            guard case .http(_, _, let body) = error,
                body.contains("endpoint_already_bound")
            else { throw error }
        }

        // 6. Short-token issuance (register may bootstrap one directly).
        var credentials: [Credential] = []
        if registered["relay"]?.objectValue?["status"]?.stringValue == "issued",
            let token = registered["relay"]?.objectValue?["token"]?.stringValue
        {
            let relays = registered["relay"]?.objectValue?["relay_fleet"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            credentials = relays.map {
                Credential(relayUrl: $0, token: token, expiresAt: nil)
            }
        } else {
            let minted = try await post(
                "\(config.baseUrl)/api/relay/token", headers: authed,
                body: ["endpointId": .string(endpointId)], step: "relay token")
            if let list = minted["relayCredentials"]?.arrayValue {
                credentials = list.compactMap { entry in
                    guard let object = entry.objectValue,
                        let url = object["relayUrl"]?.stringValue,
                        let token = object["token"]?.stringValue
                    else { return nil }
                    return Credential(
                        relayUrl: url, token: token,
                        expiresAt: object["expiresAt"]?.intValue)
                }
            } else if let token = minted["token"]?.stringValue {
                let relays = minted["relays"]?.arrayValue?.compactMap(\.stringValue) ?? []
                credentials = relays.map {
                    Credential(relayUrl: $0, token: token, expiresAt: minted["expiresAt"]?.intValue)
                }
            }
        }
        guard !credentials.isEmpty else { throw BrokerError.shape("no credentials issued") }
        if let preferredUrl, let index = credentials.firstIndex(
            where: { $0.relayUrl == preferredUrl })
        {
            credentials.swapAt(0, index)
        }
        return credentials
    }

    private func post(
        _ url: String, headers: [String: String], body: [String: JSONValue], step: String
    ) async throws -> [String: JSONValue] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(JSONValue.object(body))
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw BrokerError.http(step, status, String(data: data, encoding: .utf8) ?? "")
        }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue ?? [:]
    }

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
