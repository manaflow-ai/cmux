import Foundation

/// Splits a lane frame into data channel messages of at most
/// `maxMessageBytes` and puts them back together (d2-bakeoff.md F1: SCTP
/// messages of 16 KiB and more overflowed the receiver's UDP socket and
/// stalled the association). Every lane message starts with one byte:
///
/// - `0x00` last (or only) piece of a frame on a reliable lane, or a whole
///   frame on an unordered or partial lane;
/// - `0x01` more pieces follow (reliable lanes; SCTP keeps them in order);
/// - `0x02` an indexed piece on an unordered or partial lane:
///   `u32 LE frame id | u16 LE index | u16 LE count | bytes`. Pieces may be
///   lost or reordered; a frame is delivered only when all arrived.
///
/// The `ctl` and `wg` channels carry no header.
struct MessageChunker: Sendable {
    static let last: UInt8 = 0x00
    static let more: UInt8 = 0x01
    static let indexed: UInt8 = 0x02
    static let indexedHeader = 9

    let maxMessageBytes: Int

    init(maxMessageBytes: Int) {
        self.maxMessageBytes = max(maxMessageBytes, 64)
    }

    /// The messages of one frame. `id` numbers frames on unreliable lanes.
    func split(_ frame: Data, reliable: Bool, id: UInt32) -> [Data] {
        if reliable {
            let room = maxMessageBytes - 1
            guard frame.count > room else { return [Self.message(Self.last, frame[...])] }
            var messages: [Data] = []
            messages.reserveCapacity(frame.count / room + 1)
            var offset = frame.startIndex
            while offset < frame.endIndex {
                let end = min(offset + room, frame.endIndex)
                messages.append(Self.message(end == frame.endIndex ? Self.last : Self.more, frame[offset..<end]))
                offset = end
            }
            return messages
        }
        guard frame.count > maxMessageBytes - 1 else { return [Self.message(Self.last, frame[...])] }
        let room = maxMessageBytes - Self.indexedHeader
        let count = (frame.count + room - 1) / room
        var messages: [Data] = []
        messages.reserveCapacity(count)
        for index in 0..<count {
            let start = frame.startIndex + index * room
            let end = min(start + room, frame.endIndex)
            var message = Data(capacity: Self.indexedHeader + end - start)
            message.append(Self.indexed)
            withUnsafeBytes(of: id.littleEndian) { message.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(index).littleEndian) { message.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(count).littleEndian) { message.append(contentsOf: $0) }
            message.append(frame[start..<end])
            messages.append(message)
        }
        return messages
    }

    private static func message(_ flag: UInt8, _ bytes: Data.SubSequence) -> Data {
        var message = Data(capacity: bytes.count + 1)
        message.append(flag)
        message.append(contentsOf: bytes)
        return message
    }
}
