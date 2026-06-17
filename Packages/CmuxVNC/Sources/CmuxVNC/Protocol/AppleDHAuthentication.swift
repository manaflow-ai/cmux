import BigInt
import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Apple Diffie-Hellman authentication (VNC security type 30), used by macOS
/// Screen Sharing / Apple Remote Desktop.
///
/// The server sends DH parameters (generator, prime, its public key). The
/// client performs a DH exchange, derives an AES-128 key as `MD5(shared
/// secret)`, and sends `AES-128-ECB(key, {username[64], password[64]})`
/// followed by its own public key. Both username and password are UTF-8,
/// NUL-terminated, and padded to 64 bytes with random data.
///
/// Reference implementations: NeatVNC `src/auth/apple-dh.c`, the rfbproto spec,
/// and the Caffeinated Bitstream write-up.
public enum AppleDHAuthentication {
    /// The DH parameters a server advertises for security type 30.
    public struct ServerParams: Equatable, Sendable {
        public var generator: UInt16
        public var keyLength: Int
        public var prime: [UInt8]
        public var serverPublicKey: [UInt8]

        public init(generator: UInt16, keyLength: Int, prime: [UInt8], serverPublicKey: [UInt8]) {
            self.generator = generator
            self.keyLength = keyLength
            self.prime = prime
            self.serverPublicKey = serverPublicKey
        }
    }

    /// The client's reply: encrypted credentials followed by the client public key.
    public struct Response: Equatable, Sendable {
        public var encryptedCredentials: [UInt8] // always 128 bytes
        public var clientPublicKey: [UInt8]       // keyLength bytes
    }

    /// Computes the type-30 response. `privateKey`, when supplied, makes the DH
    /// exchange deterministic for tests; otherwise a CSPRNG value is used.
    /// `padding` (128 bytes) overrides the random credential padding for tests.
    public static func response(
        params: ServerParams,
        username: String,
        password: String,
        privateKey: [UInt8]? = nil,
        padding: [UInt8]? = nil
    ) -> Response? {
        let keyLength = params.keyLength
        guard keyLength > 0, params.prime.count == keyLength, params.serverPublicKey.count == keyLength else {
            return nil
        }

        let prime = BigUInt(Data(params.prime))
        guard prime > 0 else { return nil }
        let generator = BigUInt(params.generator)
        let priv = BigUInt(Data(privateKey ?? randomBytes(keyLength)))

        let clientPublic = generator.power(priv, modulus: prime)
        let sharedSecret = BigUInt(Data(params.serverPublicKey)).power(priv, modulus: prime)

        let sharedBytes = leftPad(sharedSecret.serialize(), to: keyLength)
        let aesKey = Array(Insecure.MD5.hash(data: Data(sharedBytes))) // 16 bytes

        let credentials = buildCredentials(username: username, password: password, padding: padding)
        guard let ciphertext = aes128ECBEncrypt(key: aesKey, plaintext: credentials), ciphertext.count == 128 else {
            return nil
        }

        let clientPublicBytes = leftPad(clientPublic.serialize(), to: keyLength)
        return Response(encryptedCredentials: ciphertext, clientPublicKey: clientPublicBytes)
    }

    /// 128-byte credential block: username in bytes 0..<64, password in
    /// 64..<128, each NUL-terminated, remaining bytes random.
    static func buildCredentials(username: String, password: String, padding: [UInt8]?) -> [UInt8] {
        var buffer = padding ?? randomBytes(128)
        if buffer.count != 128 { buffer = randomBytes(128) }
        let user = Array(username.utf8.prefix(63))
        for i in user.indices { buffer[i] = user[i] }
        buffer[user.count] = 0
        let pass = Array(password.utf8.prefix(63))
        for i in pass.indices { buffer[64 + i] = pass[i] }
        buffer[64 + pass.count] = 0
        return buffer
    }

    static func leftPad(_ data: Data, to length: Int) -> [UInt8] {
        let bytes = [UInt8](data)
        if bytes.count == length { return bytes }
        if bytes.count > length { return Array(bytes.suffix(length)) }
        return [UInt8](repeating: 0, count: length - bytes.count) + bytes
    }

    static func aes128ECBEncrypt(key: [UInt8], plaintext: [UInt8]) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128 else { return nil }
        var output = [UInt8](repeating: 0, count: plaintext.count)
        let outputCapacity = output.count
        var moved = 0
        let status = key.withUnsafeBytes { keyPtr in
            plaintext.withUnsafeBytes { dataPtr in
                output.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress, key.count,
                        nil,
                        dataPtr.baseAddress, plaintext.count,
                        outPtr.baseAddress, outputCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Array(output.prefix(moved))
    }

    static func randomBytes(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes
    }
}
