import Crypto
import Foundation
import NIOSSH

/// A parsed private key plus the metadata the key list shows.
public struct SSHParsedPrivateKey: Sendable {
    public var key: NIOSSHPrivateKey
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, ...
    public var algorithm: String
    public var comment: String
    /// OpenSSH public key line for `authorized_keys`.
    public var publicKeyLine: String
}

public enum SSHPrivateKeyParseError: Error, Equatable, Sendable {
    case notOpenSSHFormat
    /// The key is passphrase-protected and no (or a wrong) passphrase was given.
    case passphraseRequired
    case wrongPassphrase
    case unsupportedCipher(String)
    /// RSA/DSA keys are not supported by the SSH engine (PRD D8).
    case unsupportedKeyType(String)
    case malformed
}

/// Parses `-----BEGIN OPENSSH PRIVATE KEY-----` files (the `ssh-keygen` default
/// since OpenSSH 7.8) for Ed25519 and ECDSA P-256/384/521 keys.
extension SSHParsedPrivateKey {
    private static let magic = Array("openssh-key-v1\0".utf8)

    /// Parses an OpenSSH private key file.
    ///
    /// - Parameters:
    ///   - text: The armored `-----BEGIN OPENSSH PRIVATE KEY-----` file text.
    ///   - passphrase: The passphrase for an encrypted key, `nil` otherwise.
    /// - Throws: ``SSHPrivateKeyParseError``.
    public init(openSSH text: String, passphrase: String? = nil) throws {
        // iOS text input turns `--` into dashes ("smart punctuation"); undo it
        // so a hand-typed or keyboard-mangled armor line still parses.
        let text = text
            .replacingOccurrences(of: "\u{2014}", with: "--")
            .replacingOccurrences(of: "\u{2013}", with: "--")
        let body = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("OPENSSH PRIVATE KEY") }
            .joined()
        guard text.contains("BEGIN OPENSSH PRIVATE KEY"), let data = Data(base64Encoded: body) else {
            throw SSHPrivateKeyParseError.notOpenSSHFormat
        }
        var reader = SSHWireReader(Array(data))
        guard try reader.readRaw(Self.magic.count) == Self.magic else { throw SSHPrivateKeyParseError.notOpenSSHFormat }
        let cipher = try reader.readString()
        let kdf = try reader.readString()
        let kdfOptions = try reader.readBytes()
        guard try reader.readUInt32() == 1 else { throw SSHPrivateKeyParseError.malformed }
        _ = try reader.readBytes() // public key blob
        var privateBlob = try reader.readBytes()

        if cipher != "none" {
            guard let passphrase, !passphrase.isEmpty else { throw SSHPrivateKeyParseError.passphraseRequired }
            guard kdf == "bcrypt" else { throw SSHPrivateKeyParseError.unsupportedCipher(kdf) }
            privateBlob = try SSHPrivateKeyDecryption(cipher: cipher, kdfOptions: kdfOptions)
                .decrypt(privateBlob, passphrase: passphrase)
        }

        var inner = SSHWireReader(privateBlob)
        let check1 = try inner.readUInt32()
        let check2 = try inner.readUInt32()
        guard check1 == check2 else {
            throw cipher == "none" ? SSHPrivateKeyParseError.malformed : SSHPrivateKeyParseError.wrongPassphrase
        }
        let keyType = try inner.readString()
        let key: NIOSSHPrivateKey
        switch keyType {
        case "ssh-ed25519":
            _ = try inner.readBytes() // public
            let secret = try inner.readBytes() // 64 bytes: seed || public
            guard secret.count == 64 else { throw SSHPrivateKeyParseError.malformed }
            key = NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            _ = try inner.readString() // curve name
            _ = try inner.readBytes() // public point
            let scalar = try inner.readBytes().strippingLeadingZeros
            switch keyType {
            case "ecdsa-sha2-nistp256":
                key = NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 32)))
            case "ecdsa-sha2-nistp384":
                key = NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 48)))
            default:
                key = NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 66)))
            }
        default:
            throw SSHPrivateKeyParseError.unsupportedKeyType(keyType)
        }
        let comment = (try? inner.readString()) ?? ""
        self.init(
            key: key,
            algorithm: keyType,
            comment: comment,
            publicKeyLine: String(openSSHPublicKey: key.publicKey)
        )
    }
}

extension [UInt8] {
    /// An SSH `mpint` magnitude without its sign-padding zero bytes.
    fileprivate var strippingLeadingZeros: [UInt8] {
        var bytes = self
        while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
        return bytes
    }

    /// Exactly `length` big-endian bytes: zero-padded on the left, or the
    /// low-order suffix when longer.
    fileprivate func leftPadded(to length: Int) -> [UInt8] {
        count >= length ? Array(suffix(length)) : Array(repeating: 0, count: length - count) + self
    }
}

/// Minimal reader for SSH wire encoding (RFC 4251 §5).
struct SSHWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var remaining: Int { bytes.count - offset }

    mutating func readRaw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw SSHPrivateKeyParseError.malformed }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func readUInt32() throws -> UInt32 {
        try readRaw(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func readBytes() throws -> [UInt8] {
        try readRaw(Int(try readUInt32()))
    }

    mutating func readString() throws -> String {
        String(decoding: try readBytes(), as: UTF8.self)
    }
}
