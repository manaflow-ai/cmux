public import Foundation

/// One stream-plane record: `u32 channel | u64 seq | u8 flags | payload`,
/// little-endian (the cmux.wire/1 channel header that terminal-snapshot-v1
/// frames sit behind). Message carriers send one record per message;
/// byte-stream carriers prefix it with its u32 LE length (`framed`).
public struct StreamRecord: Hashable, Sendable {
    public static let headerLength = 13
    public static let lengthPrefix = 4
    public static let maxRecord = 1 << 20

    public var channel: UInt32
    /// Per channel and direction, from 1; 0 only on credit records.
    public var seq: UInt64
    public var flags: RecordFlags
    public var payload: Data

    public init(channel: UInt32, seq: UInt64, flags: RecordFlags = [], payload: Data) {
        self.channel = channel
        self.seq = seq
        self.flags = flags
        self.payload = payload
    }

    /// Decodes one record (no length prefix) and checks the header rules.
    public init(decoding data: Data) throws(RecordError) {
        guard data.count >= Self.headerLength else { throw RecordError(.truncated, "record shorter than its header") }
        guard data.count <= Self.maxRecord else { throw RecordError(.tooLarge, "record above max_record") }
        channel = UInt32(data.littleEndian(at: 0, count: 4))
        seq = data.littleEndian(at: 4, count: 8)
        flags = RecordFlags(rawValue: data[data.startIndex + 12])
        payload = data.tail(from: Self.headerLength)
        guard RecordFlags.known.isSuperset(of: flags) else {
            throw RecordError(.reservedFlags, "reserved flag bits \(flags.rawValue)")
        }
        if flags.contains(.credit) {
            guard flags == .credit, seq == 0, payload.count == 12 else {
                throw RecordError(.badCredit, "credit records carry seq 0, no other flag and 12 bytes")
            }
        } else {
            guard seq != 0 else { throw RecordError(.badSeq, "data records start at seq 1") }
            if flags.contains(.json) { _ = try jsonObject() }
        }
    }

    /// Header plus payload.
    public var encoded: Data {
        var out = Data(capacity: Self.headerLength + payload.count)
        out.appendLittleEndian(UInt64(channel), count: 4)
        out.appendLittleEndian(seq, count: 8)
        out.append(flags.rawValue)
        out.append(payload)
        return out
    }

    /// The byte-stream carrier encoding: u32 LE length, then the record.
    public var framed: Data {
        let body = encoded
        var out = Data(capacity: Self.lengthPrefix + body.count)
        out.appendLittleEndian(UInt64(body.count), count: 4)
        out.append(body)
        return out
    }

    public static func credit(channel: UInt32, grant: CreditGrant) -> StreamRecord {
        var payload = Data(capacity: 12)
        payload.appendLittleEndian(grant.ackSeq, count: 8)
        payload.appendLittleEndian(UInt64(grant.grantBytes), count: 4)
        return StreamRecord(channel: channel, seq: 0, flags: .credit, payload: payload)
    }

    /// A JSON record with the canonical encoding (sorted keys, no whitespace).
    public static func json(channel: UInt32, seq: UInt64, object: JSONValue, flags: RecordFlags = []) throws -> StreamRecord {
        StreamRecord(channel: channel, seq: seq, flags: flags.union(.json), payload: try object.canonicalData())
    }

    public func credit() throws(RecordError) -> CreditGrant {
        guard flags.contains(.credit), payload.count == 12 else { throw RecordError(.badCredit, "not a credit record") }
        return CreditGrant(ackSeq: payload.littleEndian(at: 0, count: 8),
                           grantBytes: UInt32(payload.littleEndian(at: 8, count: 4)))
    }

    /// The JSON object of a `json` record.
    public func jsonObject() throws(RecordError) -> JSONValue {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: payload), value.objectValue != nil else {
            throw RecordError(.badJSON, "json record payload is not a JSON object")
        }
        return value
    }
}
