import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Classic VNC authentication (security type 2, RFC 6143 section 7.2.2):
/// DES-ECB over the 16-byte challenge, keyed by the first 8 password bytes
/// with each byte's bits reversed.
struct VNCPasswordAuthentication {
    var password: String

    func response(challenge: [UInt8]) -> [UInt8]? {
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() { key[index] = Self.reverseBits(byte) }
        return CipherECB(algorithm: CCAlgorithm(kCCAlgorithmDES), key: key).encrypt(challenge)
    }

    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0 ..< 8 {
            result = result << 1 | value & 1
            value >>= 1
        }
        return result
    }
}

/// Apple Diffie-Hellman authentication (security type 30), macOS Screen
/// Sharing. The client finishes the DH exchange, keys AES-128-ECB with
/// MD5(shared secret), and sends the encrypted 128-byte credential block
/// (user name and password, each NUL-terminated in 64 bytes of random
/// padding) followed by its public key.
struct AppleDHAuthentication {
    var generator: UInt16
    var prime: [UInt8]
    var serverPublicKey: [UInt8]

    struct Response: Equatable {
        var encryptedCredentials: [UInt8]
        var clientPublicKey: [UInt8]
    }

    /// `privateKey` and `padding` make the result deterministic for tests.
    func response(username: String, password: String, privateKey: [UInt8]? = nil, padding: [UInt8]? = nil) -> Response? {
        let length = prime.count
        guard length > 0, serverPublicKey.count == length, let math = ModularExponentiation(modulus: prime) else { return nil }
        let secret = privateKey ?? Self.randomBytes(length)
        let generatorBytes = [UInt8(generator >> 8), UInt8(generator & 0xFF)]
        let clientPublic = math.power(generatorBytes, secret)
        let shared = math.power(serverPublicKey, secret)
        let key = Array(Insecure.MD5.hash(data: Data(shared)))
        let credentials = Self.credentials(username: username, password: password, padding: padding)
        guard let encrypted = CipherECB(algorithm: CCAlgorithm(kCCAlgorithmAES128), key: key).encrypt(credentials),
              encrypted.count == 128 else { return nil }
        return Response(encryptedCredentials: encrypted, clientPublicKey: clientPublic)
    }

    static func credentials(username: String, password: String, padding: [UInt8]?) -> [UInt8] {
        var block = padding.flatMap { $0.count == 128 ? $0 : nil } ?? randomBytes(128)
        let user = Array(username.utf8.prefix(63))
        block.replaceSubrange(0 ..< user.count, with: user)
        block[user.count] = 0
        let pass = Array(password.utf8.prefix(63))
        block.replaceSubrange(64 ..< 64 + pass.count, with: pass)
        block[64 + pass.count] = 0
        return block
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0 ... 255, using: &generator) }
        }
        return bytes
    }
}

/// One-shot ECB encryption with CommonCrypto (no padding).
struct CipherECB {
    var algorithm: CCAlgorithm
    var key: [UInt8]

    func encrypt(_ plaintext: [UInt8]) -> [UInt8]? {
        var output = [UInt8](repeating: 0, count: plaintext.count)
        let capacity = output.count
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            plaintext.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { out in
                    CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil, input.baseAddress, plaintext.count,
                            out.baseAddress, capacity, &moved)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }
}

/// The 16-byte VNC authentication response for a challenge (servers and
/// test fixtures check a client's answer with it).
public struct VNCPasswordResponse: Sendable, Equatable {
    public let bytes: [UInt8]

    public init(password: String, challenge: [UInt8]) {
        bytes = VNCPasswordAuthentication(password: password).response(challenge: challenge) ?? []
    }
}
