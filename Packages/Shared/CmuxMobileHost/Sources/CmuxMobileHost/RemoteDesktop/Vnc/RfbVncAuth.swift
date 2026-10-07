import CommonCrypto
public import Foundation

/// VNC authentication (RFC 6143 7.2.2): DES-ECB of the 16-byte challenge
/// with the password's first 8 bytes, each byte's bits reversed.
public struct RfbVncAuth: Sendable {
    public init() {}

    public func response(challenge: Data, password: String) throws(RfbError) -> Data {
        guard challenge.count == 16 else { throw RfbError.protocolError("challenge is not 16 bytes") }
        var key = [UInt8](repeating: 0, count: 8)
        for (index, byte) in password.utf8.prefix(8).enumerated() { key[index] = Self.reversed(byte) }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let input = [UInt8](challenge)
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, input, 16, &out, 16, &moved)
        guard status == kCCSuccess, moved == 16 else { throw RfbError.protocolError("DES failed (\(status))") }
        return Data(out)
    }

    private static func reversed(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = output << 1 | (input & 1)
            input >>= 1
        }
        return output
    }
}
