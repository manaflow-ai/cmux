import CmuxLink
import CmuxMobileWire
import Foundation

/// One `cmux.mobile/1` channel bound onto one `LinkChannel` (b5-mac-host.md
/// section 2): every link message is one A0 `StreamRecord` carrying this
/// channel's A0 id and a per-direction seq from 1. Credit records are refused;
/// the link's acks on consumption are the credit.
///
/// `receive()` has a single consumer. Sends go out one at a time in call
/// order (a FIFO gate around the link send), so A0 seqs stay contiguous even
/// while a send waits for link credit.
public actor MobileChannel {
    /// The A0 channel id (0 for the session channel).
    public nonisolated let id: UInt32
    public nonisolated let link: LinkChannel
    private var sendSeq: UInt64 = 0
    private var receiveSeq: UInt64 = 0
    /// The link reported loss: the next record's seq may jump once.
    private var afterGap = false
    private var ended = false
    private var sending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []
    private let lanes: AsyncStream<MobileDatagramLane>
    private let lanesContinuation: AsyncStream<MobileDatagramLane>.Continuation

    public init(id: UInt32, link: LinkChannel) {
        self.id = id
        self.link = link
        (lanes, lanesContinuation) = AsyncStream.makeStream(of: MobileDatagramLane.self)
    }

    /// Wraps a channel whose first record names its A0 id (`channel.open`).
    /// Reads that record and returns it with the bound channel.
    public static func accept(_ link: LinkChannel) async throws -> (MobileChannel, JSONValue) {
        guard case .message(let message)? = await Self.nextEvent(link) else {
            throw MobileWireError(code: "channel.closed", message: "channel closed before its first record")
        }
        let record: StreamRecord
        do {
            record = try StreamRecord(decoding: message.payload)
        } catch {
            throw MobileWireError(code: "proto.bad_record", message: "\(error)")
        }
        guard record.seq == 1, record.flags.contains(.json), !record.flags.contains(.credit) else {
            throw MobileWireError(code: "proto.bad_record", message: "first record must be JSON with seq 1")
        }
        let value: JSONValue
        do {
            value = try record.jsonObject()
        } catch {
            throw MobileWireError(code: "proto.bad_record", message: "\(error)")
        }
        let channel = MobileChannel(id: record.channel, link: link, receivedFirst: true)
        return (channel, value)
    }

    private init(id: UInt32, link: LinkChannel, receivedFirst: Bool) {
        self.id = id
        self.link = link
        receiveSeq = receivedFirst ? 1 : 0
        (lanes, lanesContinuation) = AsyncStream.makeStream(of: MobileDatagramLane.self)
    }

    // MARK: Datagram lanes

    /// Datagram lanes the phone paired with this channel
    /// (`cmux.mobile/datagram/<id>`, c2-browser-stream.md section 2), in
    /// arrival order; a new lane replaces the previous one. Ends when the
    /// channel does. One consumer.
    public func datagramLanes() -> AsyncStream<MobileDatagramLane> {
        lanes
    }

    /// Called by the host session server when a lane for this channel arrives.
    public func attachDatagramLane(_ link: LinkChannel) async {
        guard !ended else {
            await link.close()
            return
        }
        lanesContinuation.yield(MobileDatagramLane(channel: id, link: link))
    }

    /// `ChannelEvents` iterators are stateless handles onto the session, so a
    /// fresh one per call reads the same single sequence.
    private nonisolated static func nextEvent(_ link: LinkChannel) async -> ChannelEvent? {
        var iterator = link.events.makeAsyncIterator()
        return await iterator.next()
    }

    // MARK: Send

    /// Sends a JSON object (frame or channel message).
    public func send(json: JSONValue, flags: RecordFlags = []) async throws {
        let payload = try json.canonicalData()
        try await sendRecord(payload, flags: flags.union(.json).subtracting(.credit))
    }

    public func send(frame: MobileFrame) async throws {
        try await send(json: frame.jsonValue)
    }

    public func send(message: ChannelMessage) async throws {
        try await send(json: message.jsonValue)
    }

    /// Sends a binary record.
    public func send(binary payload: Data, flags: RecordFlags = []) async throws {
        try await sendRecord(payload, flags: flags.subtracting([.json, .credit]))
    }

    private func sendRecord(_ payload: Data, flags: RecordFlags) async throws {
        await acquireSend()
        defer { releaseSend() }
        let record = StreamRecord(channel: id, seq: sendSeq + 1, flags: flags, payload: payload)
        try await link.send(record.encoded)
        sendSeq += 1
    }

    private func acquireSend() async {
        guard sending else {
            sending = true
            return
        }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    private func releaseSend() {
        if sendWaiters.isEmpty {
            sending = false
        } else {
            sendWaiters.removeFirst().resume()
        }
    }

    /// Sends `channel.refused` and closes.
    public func refuse(code: String, message: String, retryable: Bool = false, details: JSONValue? = nil) async {
        try? await send(frame: .channelRefused(ChannelRefusedFrame(channel: id, code: code, message: message,
                                                                   retryable: retryable, details: details)))
        await finish()
    }

    /// Sends the owner's final word (`channel.closed`) and closes.
    public func close(code: String? = nil, message: String? = nil) async {
        try? await send(frame: .channelClosed(ChannelClosedFrame(channel: id, code: code, message: message)))
        await finish()
    }

    /// Closes the link channel without waiting for delivery (revocation,
    /// teardown of a peer that stopped reading).
    public func abort() async {
        lanesContinuation.finish()
        await link.close()
    }

    /// Delivers what was sent, then closes the link channel.
    public func finish() async {
        lanesContinuation.finish()
        try? await link.flush()
        await link.close()
    }

    // MARK: Receive

    /// The next record. A record that breaks the binding (wrong channel id,
    /// seq jump, credit flag, malformed header) closes the channel with
    /// `proto.bad_record` and ends the sequence.
    public func receive() async -> MobileInbound {
        if ended { return .closed(.local) }
        switch await Self.nextEvent(link) {
        case nil:
            ended = true
            lanesContinuation.finish()
            return .closed(.local)
        case .closed(let reason)?:
            ended = true
            lanesContinuation.finish()
            return .closed(reason)
        case .gap?:
            // The link lost messages its sender no longer retained; the A0
            // seq jumps by the same amount. The feature resyncs (terminals
            // reattach from a READY), so the binding accepts the jump once.
            afterGap = true
            return .gap
        case .message(let message)?:
            do {
                return try decode(message.payload)
            } catch {
                ended = true
                await close(code: "proto.bad_record", message: error.message)
                return .closed(.local)
            }
        }
    }

    private func decode(_ payload: Data) throws(MobileWireError) -> MobileInbound {
        let record: StreamRecord
        do {
            record = try StreamRecord(decoding: payload)
        } catch {
            throw MobileWireError(code: "proto.bad_record", message: "\(error)")
        }
        guard record.channel == id else {
            throw MobileWireError(code: "proto.bad_record", message: "record for channel \(record.channel) on \(id)")
        }
        guard !record.flags.contains(.credit) else {
            throw MobileWireError(code: "proto.bad_record", message: "credit records are not used on a link channel")
        }
        guard record.seq == receiveSeq + 1 || (afterGap && record.seq > receiveSeq) else {
            throw MobileWireError(code: "proto.bad_record", message: "seq \(record.seq) after \(receiveSeq)")
        }
        afterGap = false
        receiveSeq = record.seq
        if record.flags.contains(.json) {
            do {
                return .json(try record.jsonObject())
            } catch {
                throw MobileWireError(code: "proto.bad_record", message: "\(error)")
            }
        }
        return .binary(record.payload, record.flags)
    }
}
