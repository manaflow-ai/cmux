/// The identity of a problem: FNV-1a 64 over its source, message template and top frame.
public struct ErrorFingerprint: Sendable, Hashable {
    /// 16 lowercase hex digits.
    public let hex: String

    /// Hashes one problem's identity.
    /// - Parameters:
    ///   - source: The event source.
    ///   - template: The normalized message (``ErrorNormalizer/template(_:)``).
    ///   - topFrame: The top frame, or nil.
    public init(source: String, template: String, topFrame: String?) {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(source)\u{1f}\(template)\u{1f}\(topFrame ?? "")".utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let digits = String(hash, radix: 16)
        hex = String(repeating: "0", count: 16 - digits.count) + digits
    }
}
