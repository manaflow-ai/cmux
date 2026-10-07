/// The constants of `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` as WireGuard
/// uses them (whitepaper section 5.4), and the message sizes.
struct WireGuardProtocol {
    static let construction = Array("Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s".utf8)
    static let identifier = Array("WireGuard v1 zx2c4 Jason@zx2c4.com".utf8)
    static let labelMAC1 = Array("mac1----".utf8)

    static let initiationType: UInt8 = 1
    static let responseType: UInt8 = 2
    static let cookieReplyType: UInt8 = 3
    static let dataType: UInt8 = 4

    static let initiationLength = 148
    static let responseLength = 92
    static let dataHeaderLength = 16
    /// Smallest data message: header plus the tag of an empty keepalive.
    static let minimumDataLength = dataHeaderLength + WireGuardAEAD.tagLength

    static let initialChainKey = WireGuardHash.hash(construction)
    static let initialHash = WireGuardHash.hash(initialChainKey, identifier)
    /// No pre-shared key: Q is 32 zero bytes.
    static let presharedKey = [UInt8](repeating: 0, count: 32)

    /// HASH(LABEL_MAC1 || key): the mac1 key for messages sent to `key`.
    static func mac1Key(for key: [UInt8]) -> [UInt8] {
        WireGuardHash.hash(labelMAC1, key)
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) }
    }

    static func le64(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) }
    }

    static func readLE32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    static func readLE64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }

    /// Constant-time comparison for MACs.
    static func equal(_ lhs: ArraySlice<UInt8>, _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}
