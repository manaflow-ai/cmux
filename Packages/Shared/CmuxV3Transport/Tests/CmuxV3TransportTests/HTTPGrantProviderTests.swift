import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxV3Transport

private final class V3URLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var response: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let result = Self.response?(request) ?? (500, Data())
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: result.0, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct HTTPProof: Decodable {
    let publicKey: String
    let nonce: UUID
    let issuedAt: UInt64
    let signature: String
    enum CodingKeys: String, CodingKey { case publicKey = "public_key"; case nonce; case issuedAt = "issued_at"; case signature }
}
private struct HTTPAuthorization: Decodable {
    let team: String
    let destination: String
    let action: String
}
private struct HTTPRequest: Decodable { let request: HTTPAuthorization; let proof: HTTPProof }
private struct ProofPayload: Encodable {
    let team: String
    let destination: String
    let action: String
}
private struct ProofMessage: Encodable {
    let audience: String
    let user: String
    let path: String
    let nonce: UUID
    let issuedAt: UInt64
    let payload: ProofPayload
    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode("cmux-v3-device-proof")
        try values.encode(audience)
        try values.encode(user)
        try values.encode("POST")
        try values.encode(path)
        try values.encode(nonce)
        try values.encode(issuedAt)
        try values.encode(payload)
    }
}

@Test
func HTTPGrantProviderUsesStackBearerOnlyForConfiguredOriginAndSignsDeviceProof() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let peer = "12D3KooWPeer"
    let route = try CmxAttachRoute(id: "v3", kind: .v3,
        endpoint: .v3Peer(try CmxV3PeerIdentity(peerID: peer, addresses: ["/ip4/203.0.113.1/tcp/4001"])))
    let request = CmxByteTransportRequest(route: route, expectedPeerDeviceID: nil, authorizationMode: .transportAdmission)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [V3URLProtocol.self]
    let session = URLSession(configuration: configuration)
    V3URLProtocol.lock.lock()
    V3URLProtocol.requests = []
    V3URLProtocol.response = { request in
        switch request.url?.path {
        case "/v3/directory":
            return (200, Data(#"{"team":"team","revision":1,"devices":[{"peer_id":"12D3KooWPeer","device_id":"device-1","owner_user_id":"user","active":true,"tags":[],"lease":{"offline":{"mode":"bounded","seconds":60},"renew_every_seconds":10}}]}"#.utf8))
        case "/v3/authorize":
            return (200, Data(#"{"grant":"signed-grant"}"#.utf8))
        default: return (404, Data())
        }
    }
    V3URLProtocol.lock.unlock()
    let provider = try CmxV3HTTPGrantProvider(configuration: .init(
        origin: URL(string: "https://control.example")!, audience: "staging",
        team: "team", deviceID: "device-source", signingKey: try CmxV3SigningKey(rawRepresentation: key.rawRepresentation),
        accessToken: { "stack-token" }, userID: { "user" }
    ), session: session)
    let authorization = try await provider.authorization(for: request, source: "source-peer")
    #expect(authorization.deviceID == "device-1")
    #expect(authorization.peerID == peer)
    #expect(authorization.grant == "signed-grant")
    V3URLProtocol.lock.lock()
    let requests = V3URLProtocol.requests
    V3URLProtocol.lock.unlock()
    #expect(requests.count == 2)
    for request in requests {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stack-token")
        #expect(request.url?.host == "control.example")
    }
    let authBody = try #require(requests.last?.httpBody)
    let authRequest = try JSONDecoder().decode(HTTPRequest.self, from: authBody)
    let payload = ProofPayload(team: authRequest.request.team, destination: authRequest.request.destination, action: authRequest.request.action)
    let message = try JSONEncoder().encode(ProofMessage(audience: "staging", user: "user", path: "/v3/authorize", nonce: authRequest.proof.nonce, issuedAt: authRequest.proof.issuedAt, payload: payload))
    let signature = try #require(Data(hexString: authRequest.proof.signature))
    #expect(Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation).isValidSignature(signature, for: message))
}

@Test
func HTTPGrantProviderRejectsNonHTTPSOrigins() {
    let result = try? CmxV3HTTPGrantProvider.Configuration(origin: URL(string: "http://control.example")!, audience: "a", team: "t", deviceID: "d", signingKey: try! CmxV3SigningKey(rawRepresentation: Data(repeating: 1, count: 32)), accessToken: { "" }, userID: { "" })
    #expect(result == nil)
}

private extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        self.init(capacity: hexString.count / 2)
        for index in stride(from: 0, to: hexString.count, by: 2) {
            let start = hexString.index(hexString.startIndex, offsetBy: index)
            let end = hexString.index(start, offsetBy: 2)
            guard let byte = UInt8(String(hexString[start..<end]), radix: 16) else { return nil }
            append(byte)
        }
    }
}
