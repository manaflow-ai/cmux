import CryptoKit
public import Foundation

/// An install's or host's overlay IPv6 address: `fd7c:6d78::/32` plus 96
/// bits of SHA-256 of its id (transport.md section 3.1). Stable across key
/// rotation and unique without allocation.
public struct OverlayAddress: Sendable, Hashable, CustomStringConvertible {
    public let bytes: Data

    public init(id: String) {
        let digest = SHA256.hash(data: Data(id.utf8))
        bytes = Data([0xFD, 0x7C, 0x6D, 0x78] + Array(digest.prefix(12)))
    }

    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        self.bytes = Data(bytes)
    }

    public var description: String {
        stride(from: 0, to: 16, by: 2).map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }.joined(separator: ":")
    }
}
