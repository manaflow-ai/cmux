import CMUXMobileCore
import CryptoKit
import Foundation

/// HTTP client for the Rust control authority. It sends Stack access tokens
/// only to the configured HTTPS origin and sends signed device proofs for each
/// authorization operation. Directory addresses remain untrusted hints.
public struct CmxV3HTTPGrantProvider: CmxV3GrantProviding, Sendable {
    public struct Configuration: Sendable {
        public let origin: URL
        public let audience: String
        public let team: String
        public let deviceID: String
        public let signingKey: CmxV3SigningKey
        public let accessToken: @Sendable () async throws -> String
        public let userID: @Sendable () async throws -> String

        public init(origin: URL, audience: String, team: String, deviceID: String,
                    signingKey: CmxV3SigningKey,
                    accessToken: @escaping @Sendable () async throws -> String,
                    userID: @escaping @Sendable () async throws -> String) throws {
            guard origin.scheme?.lowercased() == "https" || origin.host == "127.0.0.1" || origin.host == "localhost" else {
                throw CmxV3HTTPGrantError.insecureOrigin
            }
            guard !audience.isEmpty, !team.isEmpty, !deviceID.isEmpty else { throw CmxV3HTTPGrantError.invalidConfiguration }
            self.origin = origin; self.audience = audience; self.team = team; self.deviceID = deviceID
            self.signingKey = signingKey; self.accessToken = accessToken; self.userID = userID
        }
    }

    private let configuration: Configuration
    private let session: URLSession
    public init(configuration: Configuration, session: URLSession = .shared) { self.configuration = configuration; self.session = session }

    public func authorization(for request: CmxByteTransportRequest, source: String) async throws -> CmxV3Authorization {
        let directory: Directory = try await post("/v3/directory", body: DirectoryRequest(team: configuration.team))
        guard let target = directory.devices.first(where: { $0.peerID == request.route.v3PeerID }) else { throw CmxV3HTTPGrantError.unknownPeer }
        let payload = AuthorizationPayload(team: configuration.team, destination: target.peerID, action: "connect")
        let grant: GrantResponse = try await post("/v3/authorize", body: Signed(request: payload, proof: try await proof(path: "/v3/authorize", payload: payload)))
        return CmxV3Authorization(deviceID: target.deviceID, peerID: target.peerID, grant: grant.grant)
    }

    public func relayGrant(for request: CmxByteTransportRequest, source: String, relay: String) async throws -> String? {
        let payload = AuthorizationPayload(team: configuration.team, destination: relay, action: "relay_reserve")
        let grant: GrantResponse = try await post("/v3/authorize", body: Signed(request: payload, proof: try await proof(path: "/v3/authorize", payload: payload)))
        return grant.grant
    }

    private func proof<T: Encodable>(path: String, payload: T) async throws -> CmxV3DeviceProof {
        let nonce = UUID(); let issued = UInt64(Date().timeIntervalSince1970)
        let user = try await configuration.userID
        let message = try ProofMessage(audience: configuration.audience, user: user, path: path, nonce: nonce, issuedAt: issued, payload: payload).encoded()
        return CmxV3DeviceProof(publicKey: configuration.signingKey.publicKeyHex,
            nonce: nonce, issuedAt: issued, signature: configuration.signingKey.sign(message))
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body) async throws -> Response {
        guard let url = URL(string: path, relativeTo: configuration.origin), url.host == configuration.origin.host else { throw CmxV3HTTPGrantError.invalidConfiguration }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(try await configuration.accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard data.count <= 64 * 1024, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw CmxV3HTTPGrantError.requestFailed }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

public struct CmxV3SigningKey: Sendable {
    private let key: Curve25519.Signing.PrivateKey
    public init(rawRepresentation: Data) throws {
        do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawRepresentation) }
        catch { throw CmxV3HTTPGrantError.invalidConfiguration }
    }
    fileprivate var publicKeyHex: String { key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined() }
    fileprivate func sign(_ message: Data) -> String { (try? key.signature(for: message).map { String(format: "%02x", $0) }.joined()) ?? "" }
}

public enum CmxV3HTTPGrantError: Error, Equatable, Sendable { case insecureOrigin, invalidConfiguration, unknownPeer, requestFailed }
private struct DirectoryRequest: Encodable { let team: String }
private struct AuthorizationPayload: Codable { let team: String; let destination: String; let action: String }
private struct Signed<Request: Encodable>: Encodable { let request: Request; let proof: CmxV3DeviceProof }
private struct CmxV3DeviceProof: Codable { let publicKey: String; let nonce: UUID; let issuedAt: UInt64; let signature: String; enum CodingKeys: String, CodingKey { case publicKey = "public_key"; case nonce; case issuedAt = "issued_at"; case signature } }
private struct GrantResponse: Decodable { let grant: String }
private struct Directory: Decodable { let devices: [DirectoryDevice] }
private struct DirectoryDevice: Decodable { let peerID: String; let deviceID: String; enum CodingKeys: String, CodingKey { case peerID = "peer_id"; case deviceID = "device_id" } }
private struct ProofMessage<Payload: Encodable>: Encodable {
    let audience: String; let user: String; let path: String; let nonce: UUID; let issuedAt: UInt64; let payload: Payload
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode("cmux-v3-device-proof"); try container.encode(audience); try container.encode(user); try container.encode("POST"); try container.encode(path); try container.encode(nonce); try container.encode(issuedAt); try container.encode(payload)
    }
    func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

private extension CmxAttachRoute {
    var v3PeerID: String? { if case let .v3Peer(identity) = endpoint { return identity.peerID }; return nil }
}
