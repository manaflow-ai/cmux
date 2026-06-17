import XCTest
import CryptoKit
import CommonCrypto
@testable import CmuxVNC

final class AppleDHAuthenticationTests: XCTestCase {
    // MARK: Credential layout

    func testCredentialLayout() {
        let padding = [UInt8](repeating: 0xAA, count: 128)
        let cred = AppleDHAuthentication.buildCredentials(username: "alice", password: "s3cret", padding: padding)
        XCTAssertEqual(cred.count, 128)
        // Username at 0..<64, NUL-terminated.
        XCTAssertEqual(Array(cred[0..<5]), Array("alice".utf8))
        XCTAssertEqual(cred[5], 0)
        XCTAssertEqual(cred[6], 0xAA) // random padding preserved past the NUL
        // Password at 64..<128, NUL-terminated.
        XCTAssertEqual(Array(cred[64..<70]), Array("s3cret".utf8))
        XCTAssertEqual(cred[70], 0)
        XCTAssertEqual(cred[71], 0xAA)
    }

    func testCredentialTruncatesLongFields() {
        let longName = String(repeating: "x", count: 100)
        let cred = AppleDHAuthentication.buildCredentials(username: longName, password: longName, padding: [UInt8](repeating: 0, count: 128))
        // Truncated to 63 bytes + NUL terminator at index 63.
        XCTAssertEqual(cred[63], 0)
        XCTAssertEqual(cred[127], 0)
        XCTAssertEqual(Array(cred[0..<63]), Array(repeating: UInt8(ascii: "x"), count: 63))
    }

    // MARK: AES-128-ECB (FIPS-197 known-answer)

    func testAES128ECBKnownAnswer() {
        let key: [UInt8] = [0x2b,0x7e,0x15,0x16,0x28,0xae,0xd2,0xa6,0xab,0xf7,0x15,0x88,0x09,0xcf,0x4f,0x3c]
        let plaintext: [UInt8] = [0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a]
        let expected: [UInt8] = [0x3a,0xd7,0x7b,0xb4,0x0d,0x7a,0x36,0x60,0xa8,0x9e,0xca,0xf3,0x24,0x66,0xef,0x97]
        XCTAssertEqual(AppleDHAuthentication.aes128ECBEncrypt(key: key, plaintext: plaintext), expected)
    }

    // MARK: Full DH response with tiny deterministic parameters

    func testResponseWithKnownSmallDHParameters() throws {
        // p=23, g=5, server public=8, client private=6 (1-byte key length).
        // clientPub = 5^6 mod 23 = 8 ; shared = 8^6 mod 23 = 13 (computed by hand).
        let params = AppleDHAuthentication.ServerParams(
            generator: 5, keyLength: 1, prime: [23], serverPublicKey: [8]
        )
        let padding = (0..<128).map { UInt8($0) }
        let resp = try XCTUnwrap(AppleDHAuthentication.response(
            params: params, username: "bob", password: "pw", privateKey: [6], padding: padding
        ))

        XCTAssertEqual(resp.clientPublicKey, [8], "5^6 mod 23 == 8")
        XCTAssertEqual(resp.encryptedCredentials.count, 128)

        // Reconstruct the expected ciphertext from the known shared secret (13).
        let aesKey = Array(Insecure.MD5.hash(data: Data([13])))
        let expectedCreds = AppleDHAuthentication.buildCredentials(username: "bob", password: "pw", padding: padding)
        let expectedCipher = AppleDHAuthentication.aes128ECBEncrypt(key: aesKey, plaintext: expectedCreds)
        XCTAssertEqual(resp.encryptedCredentials, expectedCipher)

        // And decrypting with the shared key recovers the credentials.
        let recovered = aes128ECBDecrypt(key: aesKey, ciphertext: resp.encryptedCredentials)
        XCTAssertEqual(Array(recovered[0..<3]), Array("bob".utf8))
        XCTAssertEqual(Array(recovered[64..<66]), Array("pw".utf8))
    }

    func testResponseRejectsMismatchedLengths() {
        let params = AppleDHAuthentication.ServerParams(
            generator: 2, keyLength: 4, prime: [1, 2, 3], serverPublicKey: [1, 2, 3, 4]
        )
        XCTAssertNil(AppleDHAuthentication.response(params: params, username: "a", password: "b"))
    }

    private func aes128ECBDecrypt(key: [UInt8], ciphertext: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: ciphertext.count)
        let cap = out.count
        var moved = 0
        _ = key.withUnsafeBytes { k in ciphertext.withUnsafeBytes { c in out.withUnsafeMutableBytes { o in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionECBMode),
                    k.baseAddress, key.count, nil, c.baseAddress, ciphertext.count, o.baseAddress, cap, &moved)
        }}}
        return Array(out.prefix(moved))
    }
}
