#if os(macOS)
@testable import CmuxMobileSSH
import Foundation
import Testing

/// Parses keys generated on the fly by the system `ssh-keygen`.
@Suite struct SSHPrivateKeyParserTests {
    struct GeneratedKey {
        var privateText: String
        var publicLine: String
    }

    static func generate(
        type: String,
        bits: Int? = nil,
        passphrase: String = "",
        cipher: String? = nil,
        rounds: Int? = nil
    ) throws -> GeneratedKey {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-keytest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("key").path
        var args = ["-q", "-t", type, "-N", passphrase, "-C", "test@cmux", "-f", path]
        if let bits { args += ["-b", String(bits)] }
        if let cipher { args += ["-Z", cipher] }
        if let rounds { args += ["-a", String(rounds)] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let privateText = try String(contentsOfFile: path, encoding: .utf8)
        let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
        let fields = pub.split(separator: " ")
        return GeneratedKey(privateText: privateText, publicLine: fields.prefix(2).joined(separator: " "))
    }

    static let keyTypes: [(String, Int?, String)] = [
        ("ed25519", nil, "ssh-ed25519"),
        ("ecdsa", 256, "ecdsa-sha2-nistp256"),
        ("ecdsa", 384, "ecdsa-sha2-nistp384"),
        ("ecdsa", 521, "ecdsa-sha2-nistp521"),
    ]

    @Test(arguments: [false, true])
    func parsesGeneratedKeys(encrypted: Bool) throws {
        for (type, bits, algorithm) in Self.keyTypes {
            let generated = try Self.generate(type: type, bits: bits, passphrase: encrypted ? "pw" : "")
            let parsed = try SSHParsedPrivateKey(openSSH: generated.privateText, passphrase: encrypted ? "pw" : nil)
            #expect(parsed.algorithm == algorithm)
            #expect(parsed.comment == "test@cmux")
            #expect(parsed.publicKeyLine == generated.publicLine)
        }
    }

    @Test(arguments: ["aes256-ctr", "aes128-ctr", "aes192-ctr", "aes256-cbc", "aes128-cbc"])
    func decryptsSupportedCiphers(cipher: String) throws {
        let generated = try Self.generate(type: "ed25519", passphrase: "correct horse", cipher: cipher, rounds: 4)
        #expect(generated.privateText.isEmpty == false)
        let parsed = try SSHParsedPrivateKey(openSSH: generated.privateText, passphrase: "correct horse")
        #expect(parsed.publicKeyLine == generated.publicLine)
    }

    @Test func gcmCipherIsReportedUnsupported() throws {
        let generated = try Self.generate(type: "ed25519", passphrase: "pw", cipher: "aes256-gcm@openssh.com", rounds: 4)
        #expect(throws: SSHPrivateKeyParseError.unsupportedCipher("aes256-gcm@openssh.com")) {
            try SSHParsedPrivateKey(openSSH: generated.privateText, passphrase: "pw")
        }
    }

    @Test func wrongPassphraseIsDetected() throws {
        for (type, bits, _) in Self.keyTypes.prefix(2) {
            let generated = try Self.generate(type: type, bits: bits, passphrase: "pw", rounds: 4)
            #expect(throws: SSHPrivateKeyParseError.wrongPassphrase) {
                try SSHParsedPrivateKey(openSSH: generated.privateText, passphrase: "nope")
            }
        }
    }

    @Test func missingPassphraseIsRequired() throws {
        let generated = try Self.generate(type: "ed25519", passphrase: "pw", rounds: 4)
        #expect(throws: SSHPrivateKeyParseError.passphraseRequired) {
            try SSHParsedPrivateKey(openSSH: generated.privateText)
        }
        #expect(throws: SSHPrivateKeyParseError.passphraseRequired) {
            try SSHParsedPrivateKey(openSSH: generated.privateText, passphrase: "")
        }
    }

    @Test func rsaKeyIsUnsupported() throws {
        let generated = try Self.generate(type: "rsa", bits: 2048)
        #expect(throws: SSHPrivateKeyParseError.unsupportedKeyType("ssh-rsa")) {
            try SSHParsedPrivateKey(openSSH: generated.privateText)
        }
    }

    @Test func rejectsNonOpenSSHText() {
        #expect(throws: SSHPrivateKeyParseError.notOpenSSHFormat) {
            try SSHParsedPrivateKey(openSSH: "-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----")
        }
    }

    // MARK: bcrypt_pbkdf known answers

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// OpenBSD regress vector (lib/libutil/bcrypt_pbkdf), also produced by pyca `bcrypt.kdf`.
    @Test func bcryptPBKDFMatchesOpenBSDVector() {
        let key = BcryptPBKDF(rounds: 4).derive(password: Array("password".utf8), salt: Array("salt".utf8), keyLength: 32)
        #expect(Self.hex(key) == "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
    }

    /// 48-byte output (aes256-ctr key + IV) at OpenSSH's default 16 rounds; vector from pyca `bcrypt.kdf`.
    @Test func bcryptPBKDFMatchesSixteenRoundVector() {
        let start = ContinuousClock.now
        let key = BcryptPBKDF(rounds: 16).derive(password: Array("pw".utf8), salt: Array(0..<16), keyLength: 48)
        let elapsed = ContinuousClock.now - start
        print("bcrypt_pbkdf 16 rounds, 48 bytes: \(elapsed)")
        #expect(Self.hex(key) == "936104ab12ea59c4b74d9f0074669f9d7ed6afaffa1471b35c71a87e8693e967d9d12c0bf877293a149ff6a3047d4dbc")
        let other = BcryptPBKDF(rounds: 16).derive(password: Array("password".utf8), salt: Array("salt".utf8), keyLength: 48)
        #expect(Self.hex(other) == "c339d704ec235f27690d3f12167c05a55bf86d572f270adbf9fe04c379da5f8c7942a939245dbb39ebe26fc2bd19b88b")
    }

    @Test func acceptsSmartPunctuationMangledArmor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-smart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("k").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", path]
        try process.run()
        process.waitUntilExit()
        let original = try String(contentsOfFile: path, encoding: .utf8)
        // iOS smart punctuation turns each "--" into an em dash.
        let mangled = original.replacingOccurrences(of: "--", with: "\u{2014}")
        #expect(try SSHParsedPrivateKey(openSSH: mangled).publicKeyLine == SSHParsedPrivateKey(openSSH: original).publicKeyLine)
    }
}
#endif
