public import Foundation

/// Splits encoded frames into `cmux.rd/1` video datagrams (cmux-rd-core
/// `Packetizer` without parity): data shards of equal size, the last one
/// zero-padded, consecutive transport sequence numbers across every
/// datagram the sender makes.
public struct RdPacketizer: Sendable {
    public var stream: UInt16
    public private(set) var maxDatagram: Int
    private var nextTransportSeq: UInt16 = 0

    /// Rd payload per datagram on a CmuxLink datagram lane: a 13-byte A0
    /// record header, a 1-byte rd stream type and the rd datagram stay
    /// under 1232 bytes (IPv6 minimum MTU minus WireGuard/UDP overhead).
    public static let laneDatagram = 1200
    /// Rd datagram size in stream mode (the reliable browser channel).
    public static let streamDatagram = 16 * 1024

    public init(stream: UInt16 = 0, maxDatagram: Int) {
        self.stream = stream
        self.maxDatagram = max(64, maxDatagram)
    }

    public var shardLength: Int { maxDatagram - RdDatagramHeader.length }

    public mutating func setMaxDatagram(_ value: Int) {
        maxDatagram = max(64, value)
    }

    /// The datagrams of one frame, in shard order.
    public mutating func packetize(frame: UInt32, flags: RdFrameFlags, body: RdFrameBody) throws(RdWireError) -> [Data] {
        let bytes = body.encoded
        let shard = shardLength
        let count = (bytes.count + shard - 1) / shard
        guard count >= 1, UInt32(count) <= RdDatagramHeader.maxFrameShards else {
            throw RdWireError("frame needs \(count) shards")
        }
        var out: [Data] = []
        out.reserveCapacity(count)
        for index in 0..<count {
            let start = bytes.startIndex + index * shard
            var payload = Data(bytes[start..<min(start + shard, bytes.endIndex)])
            if payload.count < shard { payload.append(Data(count: shard - payload.count)) }
            let header = RdDatagramHeader(flags: flags, kind: .video, stream: stream, frame: frame, index: UInt16(index),
                                          count: UInt16(count), fecCount: 0, transportSeq: takeTransportSeq())
            out.append(header.datagram(payload: payload))
        }
        return out
    }

    /// One non-frame datagram (`input_ack`, `cursor_pos`, `probe`).
    public mutating func datagram(kind: RdDatagramKind, payload: Data) -> Data {
        RdDatagramHeader(kind: kind, stream: stream, transportSeq: takeTransportSeq()).datagram(payload: payload)
    }

    private mutating func takeTransportSeq() -> UInt16 {
        defer { nextTransportSeq &+= 1 }
        return nextTransportSeq
    }
}
