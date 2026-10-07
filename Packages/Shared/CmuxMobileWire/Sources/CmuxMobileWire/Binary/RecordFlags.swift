/// Flags byte of a stream-plane record (a0-rpc.md section 3.1). Bits above
/// 0x08 are reserved and refused unless a capability negotiated them.
public struct RecordFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The payload restores state by itself (terminal `snapshot_ready`).
    public static let keyframe = RecordFlags(rawValue: 0x01)
    /// The payload is one UTF-8 JSON object `{t, ...}`.
    public static let json = RecordFlags(rawValue: 0x02)
    /// Flow control: `u64 ack_seq`, `u32 grant_bytes`; seq 0, not counted.
    public static let credit = RecordFlags(rawValue: 0x04)
    /// The sender's last record on this channel direction.
    public static let fin = RecordFlags(rawValue: 0x08)

    public static let known: RecordFlags = [.keyframe, .json, .credit, .fin]

    /// Flag names in bit order, as written in schemas/mobile-rpc/fixtures/binary.json.
    public var names: [String] {
        [(RecordFlags.keyframe, "keyframe"), (.json, "json"), (.credit, "credit"), (.fin, "fin")]
            .filter { contains($0.0) }.map(\.1)
    }

    public init(names: [String]) {
        let table: [String: RecordFlags] = ["keyframe": .keyframe, "json": .json, "credit": .credit, "fin": .fin]
        self = names.reduce(into: []) { $0.formUnion(table[$1] ?? []) }
    }
}
