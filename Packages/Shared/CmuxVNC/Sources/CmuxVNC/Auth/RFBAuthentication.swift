import CommonCrypto
import CryptoKit
import Foundation

/// Classic VNC authentication (security type 2, RFC 6143 section 7.2.2):
/// DES-ECB over the 16-byte challenge, keyed by the first 8 password bytes
/// with each byte's bits reversed.
struct VNCPasswordAuthentication {
    var password: String

    func response(challenge: [UInt8]) -> [UInt8]? {
        var key = [UInt8](repeating: 0, count: 8)
        let reversed = password.utf8.prefix(8).map(Self.reverseBits)
        key.replaceSubrange(0 ..< reversed.count, with: reversed)
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
        let generatorBytes = [UInt8(truncatingIfNeeded: generator >> 8), UInt8(truncatingIfNeeded: generator)]
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

    /// Secret bytes (the DH private key, the credential padding) from
    /// SystemRandomNumberGenerator: the OS CSPRNG (arc4random_buf on Apple platforms), as
    /// Chromium's crypto::RandBytes reads the OS generator (crypto/random.cc), with no
    /// pointer into the array.
    static func randomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< max(count, 0)).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
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
        // SAFETY: CCCrypt reads key.count bytes of `key` and plaintext.count bytes of `plaintext`
        // (the counts passed), takes no IV in ECB mode, writes at most `capacity` = output.count
        // bytes into `output` and one Int into `moved`; Swift keeps every array and `moved` alive
        // and in place for this call only, and CCCrypt keeps no pointer after it returns.
        let status = unsafe CCCrypt(CCOperation(kCCEncrypt), algorithm, CCOptions(kCCOptionECBMode),
                                    key, key.count, nil, plaintext, plaintext.count, &output, capacity, &moved)
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
