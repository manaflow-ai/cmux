public import Foundation

/// One `terminal_bytes` frame after the channel header (`u32 channel`,
/// `u64 seq`, `u8 flags`): the terminal sub-header and its payload.
/// Little-endian, like the channel header (sync-and-transport.md section 4).
public struct TerminalFrame: Hashable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// Raw PTY output.
        case bytes = 0
        /// GHOSTSNP up to READY (keyframe).
        case snapshotReady = 1
        /// GHOSTSNP HISTORY pages, newest first.
        case snapshotHistory = 2
        /// SHA-256 of the host's READY encoding, sent after 2 s of idle output.
        case digest = 3
    }

    public var kind: Kind
    /// Grid generation (size-state `generation`).
    public var generation: UInt32
    /// Host PTY byte offset after this frame; for `snapshotReady`, the offset
    /// the snapshot reflects.
    public var offset: UInt64
    /// GHOSTSNP version; present for every kind but `bytes`.
    public var snapshotVersion: UInt16?
    public var payload: Data

    public init(kind: Kind, generation: UInt32, offset: UInt64, snapshotVersion: UInt16? = nil, payload: Data) {
        self.kind = kind
        self.generation = generation
        self.offset = offset
        self.snapshotVersion = kind == .bytes ? nil : snapshotVersion
        self.payload = payload
    }

    public enum DecodeError: Error, Hashable, Sendable {
        case truncated
        case unknownKind(UInt8)
        case missingVersion
    }

    /// Decodes the sub-header and payload (the channel header is already removed).
    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 13 else { throw DecodeError.truncated }
        guard let kind = Kind(rawValue: bytes[0]) else { throw DecodeError.unknownKind(bytes[0]) }
        let generation = UInt32(Self.little(bytes, 1, 4))
        let offset = Self.little(bytes, 5, 8)
        var cursor = 13
        var version: UInt16?
        if kind != .bytes {
            guard bytes.count >= 15 else { throw DecodeError.missingVersion }
            version = UInt16(Self.little(bytes, 13, 2))
            cursor = 15
        }
        self.init(kind: kind, generation: generation, offset: offset, snapshotVersion: version,
                  payload: Data(bytes[cursor...]))
    }

    /// Decodes a frame, or nil for a kind this viewer does not know (a later
    /// protocol revision); callers skip those instead of failing the channel.
    public static func decodeSkippingUnknown(_ data: Data) throws -> TerminalFrame? {
        do {
            return try TerminalFrame(decoding: data)
        } catch DecodeError.unknownKind {
            return nil
        }
    }

    /// The encoding `init(decoding:)` reads (tests and local hosts).
    public var encoded: Data {
        var out: [UInt8] = [kind.rawValue]
        out += Self.le(UInt64(generation), 4)
        out += Self.le(offset, 8)
        if let snapshotVersion { out += Self.le(UInt64(snapshotVersion), 2) }
        return Data(out) + payload
    }

    private static func little(_ bytes: [UInt8], _ start: Int, _ count: Int) -> UInt64 {
        (0..<count).reduce(0) { $0 | UInt64(bytes[start + $1]) << (8 * $1) }
    }

    private static func le(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }
}
