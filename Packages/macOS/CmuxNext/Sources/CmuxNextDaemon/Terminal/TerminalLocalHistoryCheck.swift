public import Foundation

/// The host's check of its primary-screen history at a resize cut: the
/// history row count and libghostty's history digest (the last rows'
/// codepoints and wrap flags). The view computes the same values after its
/// own reflow; a mismatch means the two histories differ, so the view drops
/// its reflowed history and asks for READY + history (`snapshot-request`,
/// reason gap).
public struct TerminalLocalHistoryCheck: Sendable, Hashable {
    public var rows: UInt64
    public var digest: Data

    public init(rows: UInt64, digest: Data) {
        self.rows = rows
        self.digest = digest
    }

    /// Lowercase or uppercase hex, two digits per byte; nil when malformed.
    static func digest(hex: String) -> Data? {
        guard !hex.isEmpty, hex.count.isMultiple(of: 2) else { return nil }
        var bytes = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// Why a view asks for a fresh READY + history (`snapshot-request`).
public enum SnapshotRequestReason: String, Sendable, Hashable, Encodable {
    case digestMismatch = "digest_mismatch"
    case gap
    case generationMismatch = "generation_mismatch"
    case attach
}
