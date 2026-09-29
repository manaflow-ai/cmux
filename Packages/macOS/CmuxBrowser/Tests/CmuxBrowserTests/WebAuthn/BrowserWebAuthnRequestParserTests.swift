import Foundation
import Testing
@testable import CmuxBrowser

@Suite
struct BrowserWebAuthnRequestParserTests {
    // Google's passkey re-authentication challenge measured 10,832 bytes.
    @Test(arguments: [16, 10_832, 64 * 1024])
    func assertionAcceptsLargeChallenges(challengeByteCount: Int) throws {
        let request = try decodeAssertion(
            challengeByteCount: challengeByteCount,
            credentialIDByteCount: 20
        )

        try request.validateNativeRequestShape()
        #expect(request.publicKey.challenge.data.count == challengeByteCount)
    }

    @Test
    func assertionRejectsChallengeAboveLimit() throws {
        #expect(throws: BrowserWebAuthnBridgeError.self) {
            try decodeAssertion(challengeByteCount: 64 * 1024 + 1, credentialIDByteCount: 20)
                .validateNativeRequestShape()
        }
    }

    @Test
    func assertionRejectsCredentialIDAboveWebAuthnLimit() throws {
        let valid = try decodeAssertion(challengeByteCount: 32, credentialIDByteCount: 1_023)
        try valid.validateNativeRequestShape()

        #expect(throws: BrowserWebAuthnBridgeError.self) {
            try decodeAssertion(challengeByteCount: 32, credentialIDByteCount: 1_024)
                .validateNativeRequestShape()
        }
    }

    private func decodeAssertion(
        challengeByteCount: Int,
        credentialIDByteCount: Int
    ) throws -> BrowserWebAuthnAssertionRequest {
        let payload: [String: Any] = [
            "publicKey": [
                "challenge": base64URL(byteCount: challengeByteCount),
                "rpId": "google.com",
                "userVerification": "preferred",
                "allowCredentials": [
                    [
                        "type": "public-key",
                        "id": base64URL(byteCount: credentialIDByteCount),
                        "transports": ["hybrid", "internal"],
                    ],
                ],
            ],
        ]
        let payloadJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )
        let envelope = try BrowserWebAuthnRequestParser.parseEnvelope(from: [
            "kind": "getCredential",
            "payload": payloadJSON,
        ])
        return try BrowserWebAuthnRequestParser.decodePayload(
            BrowserWebAuthnAssertionRequest.self,
            from: envelope
        )
    }

    private func base64URL(byteCount: Int) -> String {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
