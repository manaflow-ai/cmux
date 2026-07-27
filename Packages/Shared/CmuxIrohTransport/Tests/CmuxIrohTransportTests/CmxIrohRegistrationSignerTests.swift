import CMUXMobileCore
import CryptoKit
import Foundation
import Testing
@testable import CmuxIrohTransport

@Suite("Iroh registration signer")
struct CmxIrohRegistrationSignerTests {
    @Test("signed transcript binds exact endpoint challenge and payload")
    func signedTranscript() throws {
        let secret = Data((0..<32).map(UInt8.init))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        let endpointID = privateKey.publicKey.rawRepresentation.hex
        #expect(endpointID == "03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8")
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: secret),
            generation: 4
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        )
        let payload = try CmxIrohRegistrationPayload(
            deviceID: "123e4567-e89b-12d3-a456-426614174000",
            appInstanceID: "123e4567-e89b-12d3-a456-426614174001",
            tag: "stable",
            platform: .ios,
            displayName: "Phone",
            endpointID: endpointID,
            identityGeneration: 4,
            pairingEnabled: false,
            capabilities: ["rpc", "terminal.streams"],
            pathHints: [hint],
            directPorts: try CmxIrohDirectPorts(ipv4: 50_909, ipv6: 54_750),
            now: now
        )
        let signer = try CmxIrohRegistrationSigner(
            identity: identity,
            endpointID: endpointID
        )
        let prepared = try signer.prepare(payload: payload)
        let nonce = Data(repeating: 9, count: 32).base64URL
        let challenge = CmxIrohChallengeResponse(
            challengeID: "123e4567-e89b-12d3-a456-426614174002".uppercased(),
            nonce: nonce,
            expiresAt: "2027-01-15T08:05:00.000Z"
        )

        let request = try signer.sign(prepared: prepared, challenge: challenge)
        let canonicalChallengeID = challenge.challengeID.lowercased()
        let transcript = Data(
            "cmux/iroh/device-registration/v1\n\(canonicalChallengeID)\n\(nonce)\n\(prepared.payloadSHA256)".utf8
        )
        let signature = try #require(Data(base64URL: request.signature))
        #expect(privateKey.publicKey.isValidSignature(signature, for: transcript))
        #expect(request.payload == prepared.encodedPayload)
        #expect(request.challengeId == canonicalChallengeID)
        #expect(prepared.challengeRequest.endpointId == endpointID)
        #expect(prepared.challengeRequest.payloadSha256 == prepared.payloadSHA256)

        let payloadBytes = try #require(Data(base64URL: request.payload))
        #expect(Data(SHA256.hash(data: payloadBytes)).hex == prepared.payloadSHA256)
        let payloadObject = try #require(
            JSONSerialization.jsonObject(with: payloadBytes) as? [String: Any]
        )
        #expect(payloadObject["endpointId"] as? String == endpointID)
        #expect(payloadObject["endpointID"] == nil)
        let pathHints = try #require(payloadObject["pathHints"] as? [[String: Any]])
        let encodedHint = try #require(pathHints.first)
        #expect(encodedHint["observed_at"] is String)
        #expect(encodedHint["expires_at"] is String)
        let directPorts = try #require(payloadObject["directPorts"] as? [String: Int])
        #expect(directPorts == ["ipv4": 50_909, "ipv6": 54_750])
    }

    @Test("secret and declared endpoint must match")
    func endpointMismatch() throws {
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: Data(repeating: 3, count: 32)),
            generation: 1
        )

        #expect(throws: CmxIrohRegistrationError.endpointIdentityMismatch) {
            try CmxIrohRegistrationSigner(
                identity: identity,
                endpointID: String(repeating: "0", count: 64)
            )
        }
    }

    @Test("broker-incompatible stale hints fail before registration")
    func staleHintsFail() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hint = try CmxIrohPathHint(
            kind: .relayURL,
            value: "https://use1-1.relay.lawrence.cmux.iroh.link/",
            source: .native,
            privacyScope: .publicInternet,
            observedAt: now.addingTimeInterval(-7_200),
            expiresAt: now.addingTimeInterval(60)
        )

        #expect(throws: CmxIrohRegistrationError.invalidPayload) {
            try CmxIrohRegistrationPayload(
                deviceID: "123e4567-e89b-12d3-a456-426614174000",
                appInstanceID: "123e4567-e89b-12d3-a456-426614174001",
                tag: "stable",
                platform: .ios,
                endpointID: String(repeating: "0", count: 64),
                identityGeneration: 1,
                pairingEnabled: false,
                capabilities: [],
                pathHints: [hint],
                now: now
            )
        }
    }

    @Test("noncanonical challenge nonce is rejected")
    func malformedChallengeFails() throws {
        let secret = Data(repeating: 4, count: 32)
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: secret)
        let endpointID = privateKey.publicKey.rawRepresentation.hex
        let identity = try CmxIrohIdentityMaterial(
            secretKey: CmxIrohSecretKey(bytes: secret),
            generation: 1
        )
        let signer = try CmxIrohRegistrationSigner(identity: identity, endpointID: endpointID)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let payload = try CmxIrohRegistrationPayload(
            deviceID: "123e4567-e89b-12d3-a456-426614174000",
            appInstanceID: "123e4567-e89b-12d3-a456-426614174001",
            tag: "stable",
            platform: .ios,
            endpointID: endpointID,
            identityGeneration: 1,
            pairingEnabled: false,
            capabilities: [],
            pathHints: [],
            now: now
        )
        let prepared = try signer.prepare(payload: payload)

        #expect(throws: CmxIrohRegistrationError.invalidChallenge) {
            try signer.sign(
                prepared: prepared,
                challenge: CmxIrohChallengeResponse(
                    challengeID: "123e4567-e89b-12d3-a456-426614174002",
                    nonce: "not+base64",
                    expiresAt: "2027-01-15T08:05:00.000Z"
                )
            )
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL value: String) {
        let padding = String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(
            base64Encoded: value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + padding
        )
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
