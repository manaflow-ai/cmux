import CryptoKit
import Foundation
@testable import CmuxNextUpdater
import Testing

/// The signed web update pointer (plans/cmux-next/web-ota.md): the app reads a pointer only under
/// a signature by a trusted key, so CI's script and the app must agree on the envelope, and any
/// changed byte, other key or other channel is refused.
struct WebUpdatePointerTests {
    /// The test key: seed 1...32 (never a real signing key).
    static let seed = Data(base64Encoded: "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=")!
    static let keysJSON = Data(#"{"keys":[{"id":"65b60673d6ed884b","ed25519":"ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="}]}"#.utf8)
    static var keys: WebUpdateKeys { WebUpdateKeys(json: keysJSON) }

    /// Made by `scripts/cmux-next/web-ota-pointer.py payload` and `sign` with the test key.
    static let scriptEnvelope = Data(#"{"payload":"eyJhYmkiOjIsImFyY2hpdmUiOiJ3ZWItYnVuZGxlcy1iYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiLnRhci5neiIsImNoYW5uZWwiOiJldmVyeS1tZXJnZSIsImNvbW1pdCI6IjExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTEiLCJjb21taXR0ZWRfYXQiOjE3NjAwMDAwMDAsImtleSI6ImFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEiLCJvdXRwdXRzIjoiY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjYyIsInB1Ymxpc2hlZF9hdCI6MTc5MjU0Nzc5NSwic2NoZW1hIjoxLCJzaGEyNTYiOiJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiIiwic2l6ZSI6NDJ9","schema":1,"signatures":[{"key_id":"65b60673d6ed884b","sig":"jB6xydEsPVK4aDmrhJ2wg1/RhPOkqssFRplq8SAadaNn/M74pfXYfJtXAuNAl9rACdT70R8nKNALovwUajX0CA=="}]}"#.utf8)

    /// An envelope around `payload`, signed with the test key (or `key`).
    static func envelope(_ payload: [String: Any], key: Curve25519.Signing.PrivateKey? = nil, keyID: String = "65b60673d6ed884b") throws -> Data {
        let signer = try key ?? Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = try signer.signature(for: bytes)
        let envelope: [String: Any] = ["schema": 1, "payload": bytes.base64EncodedString(),
                                       "signatures": [["key_id": keyID, "sig": signature.base64EncodedString()]]]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    static func payload(key: String = String(repeating: "a", count: 64), abi: Int = 2, committedAt: Int = 1_760_000_000,
                        channel: String = "every-merge", sha: String = String(repeating: "b", count: 64),
                        outputs: String = String(repeating: "c", count: 64), size: Int = 42) -> [String: Any] {
        ["schema": 1, "channel": channel, "key": key, "archive": "web-bundles-\(sha).tar.gz", "sha256": sha, "size": size,
         "outputs": outputs, "abi": abi, "commit": String(repeating: "1", count: 40), "committed_at": committedAt,
         "published_at": committedAt + 60]
    }

    @Test func thePointerTheScriptSignsVerifies() throws {
        let pointer = try WebUpdatePointer.verified(Self.scriptEnvelope, keys: Self.keys, channel: "every-merge")
        #expect(pointer.abi == 2)
        #expect(pointer.committedAt == 1_760_000_000)
        #expect(pointer.size == 42)
        #expect(pointer.archiveURL(base: URL(string: "https://files.cmux.com/cmux-next-web/")!).absoluteString
            == "https://files.cmux.com/cmux-next-web/\(String(repeating: "a", count: 64))/web-bundles-\(String(repeating: "b", count: 64)).tar.gz")
    }

    @Test func aChangedPayloadByteIsRefused() throws {
        var envelope = try #require(JSONSerialization.jsonObject(with: Self.scriptEnvelope) as? [String: Any])
        let payload = try #require(Data(base64Encoded: envelope["payload"] as? String ?? ""))
        let changed = String(decoding: payload, as: UTF8.self).replacingOccurrences(of: #""size":42"#, with: #""size":43"#)
        envelope["payload"] = Data(changed.utf8).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: WebUpdateRefusal.unsigned) { try WebUpdatePointer.verified(data, keys: Self.keys, channel: "every-merge") }
    }

    @Test func anotherKeyIsRefusedEvenUnderATrustedID() throws {
        let data = try Self.envelope(Self.payload(), key: Curve25519.Signing.PrivateKey())
        #expect(throws: WebUpdateRefusal.unsigned) { try WebUpdatePointer.verified(data, keys: Self.keys, channel: "every-merge") }
    }

    @Test func anotherChannelIsRefused() throws {
        #expect(throws: WebUpdateRefusal.wrongChannel("every-merge")) {
            try WebUpdatePointer.verified(Self.scriptEnvelope, keys: Self.keys, channel: "nightly")
        }
    }

    @Test func aMalformedPayloadIsRefusedAfterItsSignature() throws {
        var payload = Self.payload()
        payload["archive"] = "../../etc/passwd"
        let data = try Self.envelope(payload)
        #expect(throws: WebUpdateRefusal.malformed("archive name")) { try WebUpdatePointer.verified(data, keys: Self.keys, channel: "every-merge") }
        let huge = try Self.envelope(Self.payload(size: WebUpdatePointer.maximumSize + 1))
        #expect(throws: WebUpdateRefusal.malformed("size \(WebUpdatePointer.maximumSize + 1)")) {
            try WebUpdatePointer.verified(huge, keys: Self.keys, channel: "every-merge")
        }
    }

    @Test func aKeyEntryWhoseIDIsNotItsDigestIsDropped() {
        let wrong = Data(#"{"keys":[{"id":"0000000000000000","ed25519":"ebVWLo/mVPlAeLES6KmLp5AfhTrmlb7X4OORC60ElmQ="}]}"#.utf8)
        #expect(WebUpdateKeys(json: wrong).keys.isEmpty)
        #expect(Self.keys.keys.count == 1)
    }

    @Test func theBundledKeysLoad() {
        #expect(!WebUpdateKeys.bundled.keys.isEmpty)
    }
}
