public import Foundation

/// Input events with consecutive sequence numbers from `firstSeq`:
/// `u32 first_seq`, `u8 n`, then the events.
public struct RdInputPacket: Hashable, Sendable {
    public var firstSeq: UInt32
    public var events: [RdInputEvent]

    public init(firstSeq: UInt32, events: [RdInputEvent]) {
        self.firstSeq = firstSeq
        self.events = events
    }

    public func encoded() throws(RdWireError) -> Data {
        guard events.count <= Int(UInt8.max) else { throw RdWireError("more than 255 events") }
        var out = Data()
        out.appendRd(firstSeq)
        out.append(UInt8(events.count))
        for event in events { try event.encode(into: &out) }
        return out
    }

    public init(decoding bytes: Data) throws(RdWireError) {
        var reader = RdByteReader(bytes)
        firstSeq = try reader.u32()
        var events: [RdInputEvent] = []
        for _ in 0..<Int(try reader.u8()) { events.append(try RdInputEvent.decode(&reader)) }
        guard reader.isEmpty else { throw RdWireError("trailing bytes") }
        self.events = events
    }
}
