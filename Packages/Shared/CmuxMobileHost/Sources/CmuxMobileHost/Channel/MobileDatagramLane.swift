import CmuxLink
import CmuxMobileWire
public import Foundation

/// An unreliable link channel paired with an A0 channel
/// (`DatagramLaneName`): records carry the paired channel's id and their
/// own per-direction seq; gaps and reordering are loss, never an error.
/// Sends never wait (a full lane drops its oldest message).
public actor MobileDatagramLane {
    public nonisolated let channel: UInt32
    private let link: LinkChannel
    private var sendSeq: UInt64 = 0
    private var closed = false

    init(channel: UInt32, link: LinkChannel) {
        self.channel = channel
        self.link = link
    }

    /// Sends one binary record; false when the lane is gone.
    @discardableResult
    public func send(_ payload: Data) async -> Bool {
        guard !closed else { return false }
        sendSeq += 1
        let record = StreamRecord(channel: channel, seq: sendSeq, payload: payload)
        do {
            try await link.send(record.encoded)
            return true
        } catch {
            closed = true
            return false
        }
    }

    /// The next binary payload, or nil when the lane closed. Records for
    /// another channel, JSON records and malformed records are skipped.
    public func receive() async -> Data? {
        while !closed {
            var iterator = link.events.makeAsyncIterator()
            switch await iterator.next() {
            case .message(let message)?:
                guard let record = try? StreamRecord(decoding: message.payload), record.channel == channel,
                      !record.flags.contains(.json), !record.flags.contains(.credit) else { continue }
                return record.payload
            case .gap?:
                continue
            case .closed?, nil:
                closed = true
            }
        }
        return nil
    }

    public func close() async {
        closed = true
        await link.close()
    }
}
