import Foundation
import Testing
@testable import CmuxBrowser

// Limits match Chromium, Firefox and WebKit: none caps challenges, credential
// IDs, strings, transports or algorithms; all reject user IDs over 64 bytes.
@Suite
struct BrowserWebAuthnRequestParserTests {
    // Google's passkey re-authentication challenge measured 10,832 bytes.
    @Test(arguments: [16, 10_832, 1024 * 1024])
    func assertionAcceptsLargeChallenges(challengeByteCount: Int) throws {
        let request = try decodeAssertion(challengeByteCount: challengeByteCount)

        try request.validateNativeRequestShape()
        #expect(request.publicKey.challenge.data.count == challengeByteCount)
    }

    @Test
    func assertionAcceptsWhatBrowsersAccept() throws {
        let request = try decodeAssertion(
            challengeByteCount: 32,
            credentialIDByteCount: 2_048,
            transports: ["hybrid", "internal", "usb", "nfc", "ble", "smart-card", "a", "b", "c"],
            userVerification: String(repeating: "x", count: 200),
            mediation: String(repeating: "y", count: 200),
            appID: "https://example.com/" + String(repeating: "z", count: 4_096)
        )

        try request.validateNativeRequestShape()
    }

    @Test
    func assertionRejectsPayloadAboveBridgeLimit() {
        let oversizedPayload = String(
            repeating: "a",
            count: BrowserWebAuthnRequestParser.maximumPayloadJSONUTF8Bytes + 1
        )
        #expect(throws: BrowserWebAuthnBridgeError.self) {
            try BrowserWebAuthnRequestParser.parseEnvelope(from: [
                "kind": "getCredential",
                "payload": oversizedPayload,
            ])
        }
    }

    @Test
    func creationAcceptsWhatBrowsersAccept() throws {
        let longName = String(repeating: "n", count: 4_096)
        let request = try decodeCreation(
            userIDByteCount: 64,
            userName: longName,
            displayName: longName,
            rpName: longName,
            algorithms: Array(-100 ... -1)
        )

        try request.validateNativeRequestShape()
    }

    @Test(arguments: [0, 65])
    func creationRejectsUserIDOutsideOneToSixtyFourBytes(userIDByteCount: Int) throws {
        let request = try decodeCreation(
            userIDByteCount: userIDByteCount,
            userName: "user",
            displayName: "User",
            rpName: "Example",
            algorithms: [-7]
        )

        #expect(throws: BrowserWebAuthnBridgeError.self) {
            try request.validateNativeRequestShape()
        }
    }

    private func decodeAssertion(
        challengeByteCount: Int,
        credentialIDByteCount: Int = 20,
        transports: [String] = ["hybrid", "internal"],
        userVerification: String = "preferred",
        mediation: String? = nil,
        appID: String? = nil
    ) throws -> BrowserWebAuthnAssertionRequest {
        var publicKey: [String: Any] = [
            "challenge": base64URL(byteCount: challengeByteCount),
            "rpId": "google.com",
            "userVerification": userVerification,
            "allowCredentials": [
                [
                    "type": "public-key",
                    "id": base64URL(byteCount: credentialIDByteCount),
                    "transports": transports,
                ],
            ],
        ]
        if let appID {
            publicKey["extensions"] = ["appid": appID]
        }
        var payload: [String: Any] = ["publicKey": publicKey]
        if let mediation {
            payload["mediation"] = mediation
        }
        return try decode(BrowserWebAuthnAssertionRequest.self, kind: "getCredential", payload: payload)
    }

    private func decodeCreation(
        userIDByteCount: Int,
        userName: String,
        displayName: String,
        rpName: String,
        algorithms: [Int]
    ) throws -> BrowserWebAuthnCreationRequest {
        let payload: [String: Any] = [
            "publicKey": [
                "challenge": base64URL(byteCount: 32),
                "rp": ["id": "example.com", "name": rpName],
                "user": [
                    "id": base64URL(byteCount: userIDByteCount),
                    "name": userName,
                    "displayName": displayName,
                ],
                "pubKeyCredParams": algorithms.map { ["type": "public-key", "alg": $0] },
            ],
        ]
        return try decode(BrowserWebAuthnCreationRequest.self, kind: "createCredential", payload: payload)
    }

    private func decode<T: Decodable>(_ type: T.Type, kind: String, payload: [String: Any]) throws -> T {
        let payloadJSON = String(
            decoding: try JSONSerialization.data(withJSONObject: payload),
            as: UTF8.self
        )
        let envelope = try BrowserWebAuthnRequestParser.parseEnvelope(from: [
            "kind": kind,
            "payload": payloadJSON,
        ])
        return try BrowserWebAuthnRequestParser.decodePayload(type, from: envelope)
    }

    private func base64URL(byteCount: Int) -> String {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
