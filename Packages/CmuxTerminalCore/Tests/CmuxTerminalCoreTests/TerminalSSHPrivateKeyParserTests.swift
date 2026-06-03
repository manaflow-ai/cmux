import Foundation
import Testing

@testable import CmuxTerminalCore

@Suite struct TerminalSSHPrivateKeyParserTests {
    /// A known unencrypted Ed25519 OpenSSH private key and its expected public key.
    private static let ed25519PrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
    QyNTUxOQAAACBEgoOV2HQ8aVLAnWgpBrWJSCuebVlMkISVd9PQbG6rjgAAAJAgT2VFIE9l
    RQAAAAtzc2gtZWQyNTUxOQAAACBEgoOV2HQ8aVLAnWgpBrWJSCuebVlMkISVd9PQbG6rjg
    AAAEC9fEApQ+272xzps6dnIpqFxD6VB8uggBCFNR0oRnowUUSCg5XYdDxpUsCdaCkGtYlI
    K55tWUyQhJV309BsbquOAAAACXRlc3RAY211eAECAwQ=
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let ed25519PublicKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIESCg5XYdDxpUsCdaCkGtYlIK55tWUyQhJV309BsbquO"

    /// A known unencrypted ECDSA P-256 OpenSSH private key and its expected public key.
    private static let ecdsaP256PrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
    1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQRrtIgnOTgEV2EsyJomOUQ+9j831Xb3
    tGS5pmD+hGg2zHOPoA0JfGcIz7Op8IshDAhmRQGezXNN9sDLVygWvLHPAAAAqBtXPzobVz
    86AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGu0iCc5OARXYSzI
    miY5RD72PzfVdve0ZLmmYP6EaDbMc4+gDQl8ZwjPs6nwiyEMCGZFAZ7Nc032wMtXKBa8sc
    8AAAAgala/0gJFzaR2j2cbZIEd0QqlFcdV2jOH1LKOQigjmawAAAAJdGVzdEBjbXV4AQID
    BAUGBw==
    -----END OPENSSH PRIVATE KEY-----
    """

    private static let ecdsaP256PublicKey =
        "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGu0iCc5OARXYSzImiY5RD72PzfVdve0ZLmmYP6EaDbMc4+gDQl8ZwjPs6nwiyEMCGZFAZ7Nc032wMtXKBa8sc8="

    @Test func parsesEd25519KeyAndDerivesPublicKey() throws {
        let parsed = try TerminalSSHPrivateKeyParser.parse(Self.ed25519PrivateKey)
        #expect(parsed.openSSHPublicKey == Self.ed25519PublicKey)
    }

    @Test func parsesECDSAP256KeyAndDerivesPublicKey() throws {
        let parsed = try TerminalSSHPrivateKeyParser.parse(Self.ecdsaP256PrivateKey)
        #expect(parsed.openSSHPublicKey == Self.ecdsaP256PublicKey)
    }

    @Test func rejectsNonPEMText() {
        #expect(throws: TerminalSSHPrivateKeyParserError.invalidFormat) {
            try TerminalSSHPrivateKeyParser.parse("not a key")
        }
    }

    @Test func rejectsMissingEndMarker() {
        let text = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmU=
        """
        #expect(throws: TerminalSSHPrivateKeyParserError.invalidFormat) {
            try TerminalSSHPrivateKeyParser.parse(text)
        }
    }

    @Test func rejectsEncryptedKey() {
        // A well-formed openssh-key-v1 header that declares aes256-ctr / bcrypt, which the
        // parser must reject as encrypted rather than attempting to read key material.
        let header = Data("openssh-key-v1\0".utf8)
        var payload = header
        payload.append(sshString("aes256-ctr"))
        payload.append(sshString("bcrypt"))
        payload.append(sshString(""))           // kdf options
        payload.append(contentsOf: [0, 0, 0, 1]) // key count
        let base64 = payload.base64EncodedString()
        let text = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        \(base64)
        -----END OPENSSH PRIVATE KEY-----
        """
        #expect(throws: TerminalSSHPrivateKeyParserError.encryptedKeysUnsupported) {
            try TerminalSSHPrivateKeyParser.parse(text)
        }
    }

    /// Encodes a string using the SSH `string` wire format (4-byte big-endian length prefix).
    private func sshString(_ value: String) -> Data {
        let bytes = Data(value.utf8)
        var out = Data()
        let length = UInt32(bytes.count)
        out.append(UInt8((length >> 24) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(bytes)
        return out
    }
}
