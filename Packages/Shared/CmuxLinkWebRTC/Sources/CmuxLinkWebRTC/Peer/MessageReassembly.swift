import Foundation

/// Reassembles one channel's messages into frames (see `MessageChunker`).
struct MessageReassembly: Sendable {
    /// Incomplete indexed frames kept per channel; older ones are dropped.
    static let maxPendingFrames = 8

    private var pending = Data()
    /// The frame in progress outgrew `maxFrameBytes`: drop its pieces up to
    /// and including its last one.
    private var discarding = false
    private var indexed: [UInt32: IndexedFrame] = [:]
    private var order: [UInt32] = []
    private let maxFrameBytes: Int

    private struct IndexedFrame {
        var pieces: [Data?]
        var received = 0
    }

    init(maxFrameBytes: Int) {
        self.maxFrameBytes = maxFrameBytes
    }

    /// The frame this message completes, if any. Malformed messages and
    /// frames above `maxFrameBytes` are dropped.
    mutating func receive(_ message: Data) -> Data? {
        guard let flag = message.first else { return nil }
        let body = message.dropFirst()
        switch flag {
        case MessageChunker.last:
            if discarding {
                discarding = false
                return nil
            }
            guard !pending.isEmpty else { return body.count <= maxFrameBytes ? Data(body) : nil }
            pending.append(contentsOf: body)
            defer { pending = Data() }
            return pending.count <= maxFrameBytes ? pending : nil
        case MessageChunker.more:
            guard !discarding else { return nil }
            pending.append(contentsOf: body)
            if pending.count > maxFrameBytes {
                pending = Data()
                discarding = true
            }
            return nil
        case MessageChunker.indexed:
            return receiveIndexed(body)
        default:
            return nil
        }
    }

    private mutating func receiveIndexed(_ body: Data.SubSequence) -> Data? {
        guard body.count >= MessageChunker.indexedHeader - 1 else { return nil }
        let bytes = Array(body.prefix(8))
        let id = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let index = Int(UInt16(bytes[4]) | UInt16(bytes[5]) << 8)
        let count = Int(UInt16(bytes[6]) | UInt16(bytes[7]) << 8)
        guard count > 0, index < count else { return nil }
        if indexed[id] == nil {
            indexed[id] = IndexedFrame(pieces: Array(repeating: nil, count: count))
            order.append(id)
            while order.count > Self.maxPendingFrames { indexed[order.removeFirst()] = nil }
        }
        guard var frame = indexed[id], frame.pieces.count == count, frame.pieces[index] == nil else { return nil }
        frame.pieces[index] = Data(body.dropFirst(8))
        frame.received += 1
        guard frame.received == count else {
            indexed[id] = frame
            return nil
        }
        indexed[id] = nil
        order.removeAll { $0 == id }
        let whole = frame.pieces.reduce(into: Data()) { $0.append($1 ?? Data()) }
        return whole.count <= maxFrameBytes ? whole : nil
    }
}
