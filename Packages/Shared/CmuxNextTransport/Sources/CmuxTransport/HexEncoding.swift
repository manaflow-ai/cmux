/// Encodes byte sequences as deterministic lowercase hexadecimal text.
///
/// The encoder is shared by frame digests and application identity bindings so
/// every transport boundary uses the same byte-for-byte representation.
public struct HexEncoding: Sendable {
    private static let digits = Array("0123456789abcdef".utf8)

    /// Creates a stateless byte encoder.
    public init() {}

    /// Returns the lowercase hexadecimal representation of `bytes`.
    ///
    /// - Parameter bytes: A sequence whose elements are raw bytes.
    /// - Returns: Two hexadecimal characters for each input byte.
    public func lowercase<Bytes: Sequence>(_ bytes: Bytes) -> String
    where Bytes.Element == UInt8 {
        var utf8 = [UInt8]()
        utf8.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            utf8.append(Self.digits[Int(byte >> 4)])
            utf8.append(Self.digits[Int(byte & 0x0F)])
        }
        return String(decoding: utf8, as: UTF8.self)
    }
}
