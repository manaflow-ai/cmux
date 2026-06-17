import Foundation
import CommonCrypto

/// Classic VNC authentication (security type 2, RFC 6143 §7.2.2).
///
/// The server sends a 16-byte random challenge. The client encrypts it with
/// single-DES in ECB mode, keyed by the password (truncated/zero-padded to 8
/// bytes). The historical quirk: each key byte's bit order is reversed before
/// use. The 16-byte response is the two encrypted 8-byte blocks.
public enum VNCAuthentication {
    /// Reverses the bit order of a byte (`0b0000_0001` -> `0b1000_0000`).
    static func reverseBits(_ byte: UInt8) -> UInt8 {
        var value = byte
        var result: UInt8 = 0
        for _ in 0 ..< 8 {
            result = (result << 1) | (value & 1)
            value >>= 1
        }
        return result
    }

    /// Builds the 8-byte DES key from a password using the VNC bit-reversal rule.
    static func desKey(from password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        let bytes = Array(password.utf8.prefix(8))
        for (index, byte) in bytes.enumerated() {
            key[index] = reverseBits(byte)
        }
        return key
    }

    /// Computes the 16-byte challenge response for `password`.
    public static func challengeResponse(challenge: [UInt8], password: String) -> [UInt8] {
        let key = desKey(from: password)
        // The challenge is always 16 bytes; encrypt as two independent ECB blocks.
        var output = [UInt8](repeating: 0, count: challenge.count)
        let outputCapacity = output.count
        var numBytesEncrypted = 0
        let status = key.withUnsafeBytes { keyPtr in
            challenge.withUnsafeBytes { dataPtr in
                output.withUnsafeMutableBytes { outPtr in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyPtr.baseAddress,
                        kCCKeySizeDES,
                        nil,
                        dataPtr.baseAddress,
                        challenge.count,
                        outPtr.baseAddress,
                        outputCapacity,
                        &numBytesEncrypted
                    )
                }
            }
        }
        guard status == kCCSuccess else { return [] }
        return Array(output.prefix(numBytesEncrypted))
    }
}
