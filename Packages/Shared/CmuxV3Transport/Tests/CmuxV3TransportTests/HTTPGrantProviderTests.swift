import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxV3Transport

private final class V3URLProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var storedRequests: [URLRequest] = []
        private var storedResponse: ((URLRequest) -> (Int, Data))?

        func configure(response: @escaping (URLRequest) -> (Int, Data)) {
            lock.lock()
            storedRequests = []
            storedResponse = response
            lock.unlock()
        }

        func record(_ request: URLRequest) -> (Int, Data) {
            lock.lock()
            storedRequests.append(request)
            let response = storedResponse?(request) ?? (500, Data())
            lock.unlock()
            return response
        }

        func requests() -> [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return storedRequests
        }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate(); stream.close() }
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 4096)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            request.httpBody = body
        }
        let result = Self.state.record(request)
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

    enum CodingKeys: String, CodingKey { case team, destination, action }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(team, forKey: .team)
        try container.encode(destination, forKey: .destination)
        try container.encode(action, forKey: .action)
    }
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
    V3URLProtocol.state.configure { request in
        switch request.url?.path {
        case "/v3/directory":
            return (200, Data(#"{"team":"team","revision":1,"devices":[{"peer_id":"12D3KooWPeer","device_id":"device-1","owner_user_id":"user","active":true,"tags":[],"lease":{"offline":{"mode":"bounded","seconds":60},"renew_every_seconds":10}}]}"#.utf8))
        case "/v3/authorize":
            return (200, Data(#"{"grant":"signed-grant"}"#.utf8))
        default: return (404, Data())
        }
    }
    let provider = try CmxV3HTTPGrantProvider(configuration: .init(
        origin: URL(string: "https://control.example")!, audience: "staging",
        team: "team", deviceID: "device-source", signingKey: try CmxV3SigningKey(rawRepresentation: key.rawRepresentation),
        accessToken: { "stack-token" }, userID: { "user" }
    ), session: session)
    let authorization = try await provider.authorization(for: request, source: "source-peer")
    #expect(authorization.deviceID == "device-1")
    #expect(authorization.peerID == peer)
    #expect(authorization.grant == "signed-grant")
    let requests = V3URLProtocol.state.requests()
    #expect(requests.count == 2)
    for request in requests {
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer stack-token")
        #expect(request.url?.host == "control.example")
    }
    let authBody = try #require(requests.last?.httpBody)
    let authRequest = try JSONDecoder().decode(HTTPRequest.self, from: authBody)
    let payload = ProofPayload(team: authRequest.request.team, destination: authRequest.request.destination, action: authRequest.request.action)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let message = try encoder.encode(ProofMessage(audience: "staging", user: "user", path: "/v3/authorize", nonce: authRequest.proof.nonce, issuedAt: authRequest.proof.issuedAt, payload: payload))
    let signature = try #require(Data(hexString: authRequest.proof.signature))
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key.publicKey.rawRepresentation)
    #expect(publicKey.isValidSignature(signature, for: message))
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
