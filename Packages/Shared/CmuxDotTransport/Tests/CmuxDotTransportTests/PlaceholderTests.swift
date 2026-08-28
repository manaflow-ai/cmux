import Testing
import CryptoKit
import Foundation
@testable import CmuxDotTransport

@Test func wireRoundTripsAndRejectsMalformedFrames() throws {
    #expect(DotWire.protocolName == "dot/1")
    let payload = Data("hello".utf8)
    let encoded = DotWire.encodeData(.init(legID: 7, seq: 9, payload: payload))
    #expect(DotWire.decodeData(encoded) == .init(legID: 7, seq: 9, payload: payload))
    #expect(DotWire.decodeData(Data(repeating: 0, count: DotWire.dataHeaderBytes - 1)) == nil)

    let control = try DotControlFrame.ping(ts: 123).encoded()
    #expect(try DotControlFrame.decode(control) == .ping(ts: 123))
}

@Test func sessionFrameRoundTripsAndBoundsBodies() throws {
    let frame = DotSessionFrame(
        kind: .data,
        streamID: 42,
        sessionID: "session",
        body: Data("ciphertext".utf8)
    )
    let encoded = try frame.encoded()
    let decoded = try #require(DotSessionFrame.decode(encoded))
    #expect(decoded.kind == .data)
    #expect(decoded.streamID == 42)
    #expect(decoded.sessionID == "session")
    #expect(decoded.body == Data("ciphertext".utf8))

    #expect(throws: DotTransportError.self) {
        try DotSessionFrame(
            kind: .data,
            streamID: 1,
            sessionID: "session",
            body: Data(repeating: 0, count: DotWire.maxDataFrameBytes + 1)
        ).encoded()
    }
}

@Test func grantVerifierAcceptsSignedGrantAndRejectsUnknownClaims() throws {
    let now = Int64(Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSince1970)
    let signingKey = Curve25519.Signing.PrivateKey()
    let initiator = DotGrantClaims.Peer(
        bindingId: "11111111-1111-4111-8111-111111111111",
        deviceId: "22222222-2222-4222-8222-222222222222",
        tag: "phone",
        platform: "ios",
        endpointId: hex(signingKey.publicKey.rawRepresentation),
        identityGeneration: 1
    )
    let acceptorKey = Curve25519.Signing.PrivateKey()
    let acceptor = DotGrantClaims.Peer(
        bindingId: "33333333-3333-4333-8333-333333333333",
        deviceId: "44444444-4444-4444-8444-444444444444",
        tag: "mac",
        platform: "mac",
        endpointId: hex(acceptorKey.publicKey.rawRepresentation),
        identityGeneration: 1
    )
    let claims = DotGrantClaims(
        jti: "55555555-5555-4555-8555-555555555555",
        iat: now,
        nbf: now,
        exp: now + 3_600,
        alpn: "cmux/mobile/1",
        scope: "cmux.mobile.attach",
        initiator: initiator,
        acceptor: acceptor
    )
    let header = Data("{\"alg\":\"EdDSA\",\"typ\":\"cmux-pair-grant+jwt\",\"kid\":\"k1\"}".utf8)
    let payload = try JSONEncoder().encode(claims)
    let encodedHeader = base64URL(header)
    let encodedPayload = base64URL(payload)
    let signingInput = Data("\(encodedHeader).\(encodedPayload)".utf8)
    let signature = try signingKey.signature(for: signingInput)
    let token = "\(encodedHeader).\(encodedPayload).\(base64URL(signature))"

    let verified = try DotGrantVerifier.verify(
        token,
        keys: [signingKey.publicKey.rawRepresentation],
        now: Date(timeIntervalSince1970: TimeInterval(now))
    )
    #expect(verified.jti == claims.jti)

    var object = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
    object["unexpected"] = true
    let unknownPayload = try JSONSerialization.data(withJSONObject: object)
    let unknownEncodedPayload = base64URL(unknownPayload)
    let unknownInput = Data("\(encodedHeader).\(unknownEncodedPayload)".utf8)
    let unknownSignature = try signingKey.signature(for: unknownInput)
    let unknownToken = "\(encodedHeader).\(unknownEncodedPayload).\(base64URL(unknownSignature))"
    #expect(throws: DotTransportError.self) {
        try DotGrantVerifier.verify(
            unknownToken,
            keys: [signingKey.publicKey.rawRepresentation],
            now: Date(timeIntervalSince1970: TimeInterval(now))
        )
    }
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}
