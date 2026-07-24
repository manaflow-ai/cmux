import CryptoKit
import Foundation
@testable import CmuxIrohTransport

struct RelayPolicyServiceTestFixture {
    let firstPrivateKey = Curve25519.Signing.PrivateKey()
    let secondPrivateKey = Curve25519.Signing.PrivateKey()
    let now = Date(timeIntervalSince1970: 1_782_000_000)
    let relayURLs = [
        "https://usc1.relay.cmux.dev/",
        "https://euw4.relay.cmux.dev/",
    ]

    var firstTrustRoot: CmxIrohRelayPolicyTrustRoot {
        get throws { try trustRoot(includeFirst: true, includeSecond: false) }
    }

    var rotatedTrustRoot: CmxIrohRelayPolicyTrustRoot {
        get throws { try trustRoot(includeFirst: true, includeSecond: true) }
    }

    var secondTrustRoot: CmxIrohRelayPolicyTrustRoot {
        get throws { try trustRoot(includeFirst: false, includeSecond: true) }
    }

    func token(
        sequence: Int64,
        signer: Int = 1,
        expiresAt: Int64? = nil,
        relayURLs: [String]? = nil
    ) throws -> String {
        let keyID = signer == 1 ? "policy-first" : "policy-second"
        let privateKey = signer == 1 ? firstPrivateKey : secondPrivateKey
        let header = try JSONSerialization.data(
            withJSONObject: [
                "alg": "EdDSA",
                "typ": "cmux-relay-policy-v1+jwt",
                "kid": keyID,
            ],
            options: [.sortedKeys]
        )
        let urls = relayURLs ?? self.relayURLs
        let descriptors = urls.enumerated().map { index, url in
            [
                "id": index == 0 ? "cmux-us" : "cmux-eu",
                "provider": "cmux",
                "region": index == 0 ? "us-central1" : "europe-west4",
                "url": url,
            ]
        }
        let nowSeconds = Int64(now.timeIntervalSince1970)
        let payload = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "jti": "123e4567-e89b-42d3-a456-426614174000",
                "sequence": sequence,
                "iat": nowSeconds,
                "nbf": nowSeconds,
                "exp": expiresAt ?? nowSeconds + 3_600,
                "aud": "cmux-iroh-relay-policy",
                "relay_protocol": "iroh-relay-v1",
                "relays": descriptors,
            ],
            options: [.sortedKeys]
        )
        let input = "\(Self.base64URL(header)).\(Self.base64URL(payload))"
        let signature = try privateKey.signature(for: Data(input.utf8))
        return "\(input).\(Self.base64URL(signature))"
    }

    func relayCredential() -> CmxIrohRelayTokenResponse {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return CmxIrohRelayTokenResponse(
            token: "aaaa",
            expiresAt: formatter.string(from: now.addingTimeInterval(3_600)),
            refreshAfter: formatter.string(from: now.addingTimeInterval(1_800)),
            relayFleet: relayURLs
        )
    }

    private func trustRoot(
        includeFirst: Bool,
        includeSecond: Bool
    ) throws -> CmxIrohRelayPolicyTrustRoot {
        var keys: [CmxIrohRelayPolicyVerificationKey] = []
        if includeFirst {
            keys.append(try CmxIrohRelayPolicyVerificationKey(
                keyID: "policy-first",
                rawPublicKeyBase64: firstPrivateKey.publicKey.rawRepresentation.base64EncodedString()
            ))
        }
        if includeSecond {
            keys.append(try CmxIrohRelayPolicyVerificationKey(
                keyID: "policy-second",
                rawPublicKeyBase64: secondPrivateKey.publicKey.rawRepresentation.base64EncodedString()
            ))
        }
        return try CmxIrohRelayPolicyTrustRoot(keys: keys)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
