import CmuxLink
import Foundation
import os
@preconcurrency import WebRTC

/// The bridge to one `RTCPeerConnection`: owns its data channels, maps lanes
/// to channels, delivers frames straight into the transport's event stream
/// (callback order, no hop), and reports everything else as `PeerEvent`s to
/// the driver. libwebrtc calls the delegates on its signaling thread.
final class WebRTCPeer: NSObject, @unchecked Sendable {
    struct State {
        var connection: RTCPeerConnection?
        var entries: [ObjectIdentifier: PeerChannelEntry] = [:]
        /// The channel each lane label sends on (ours or the peer's).
        var sendChannels: [String: RTCDataChannel] = [:]
        var control: RTCDataChannel?
        var sentCounts: [String: Int] = [:]
        var receivedCounts: [String: Int] = [:]
        var finExpected: [String: Int]?
        var finReported = false
        var openWaiters: [ObjectIdentifier: [CheckedContinuation<Void, any Error>]] = [:]
        var drainWaiters: [ObjectIdentifier: [CheckedContinuation<Void, any Error>]] = [:]
        var closed = false
        var closeOnControlClose = false
        /// Lane messages waiting for the scheduler, by lane label.
        var laneQueues: [String: LaneQueue] = [:]
        /// `send` callers waiting for room in their lane's queue.
        var roomWaiters: [String: [CheckedContinuation<Void, any Error>]] = [:]
        /// `waitFlushed` callers (graceful close).
        var flushWaiters: [CheckedContinuation<Void, Never>] = []
        var nextFrameID: UInt32 = 0
        /// Per receiving channel.
        var reassembly: [ObjectIdentifier: MessageReassembly] = [:]
        /// Reliable lane message bytes we sent, and the peer's last credit.
        var sentBytes = 0
        var creditedBytes = 0
        /// Reliable lane message bytes we received, and what we credited.
        var receivedBytes = 0
        var receivedCredited = 0
    }

    // carve-out: libwebrtc calls the delegates synchronously on its own
    // threads (frames must keep callback order with no actor hop); the lock
    // is never held while calling into libwebrtc (see the data path note).
    let state = OSAllocatedUnfairLock(uncheckedState: State())
    let factory: WebRTCFactory
    let mode: PeerMode
    let limits: PeerSendLimits
    let chunker: MessageChunker
    /// Wakes the lane scheduler: a send queued, a channel opened, a buffer
    /// drained. Newest-one buffering, so a wake is never lost and never piles up.
    let wakes: AsyncStream<Void>
    let wakeSink: AsyncStream<Void>.Continuation
    /// Driver events.
    let events: AsyncStream<PeerEvent>
    let eventSink: AsyncStream<PeerEvent>.Continuation
    /// Frames for the transport's event stream.
    let frameSink: AsyncStream<TransportEvent>.Continuation

    init(
        factory: WebRTCFactory,
        mode: PeerMode = .lanes,
        ice: ICEConfiguration,
        limits: PeerSendLimits,
        frameSink: AsyncStream<TransportEvent>.Continuation
    ) throws {
        self.factory = factory
        self.mode = mode
        self.limits = limits
        chunker = MessageChunker(maxMessageBytes: limits.maxMessageBytes)
        (wakes, wakeSink) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.frameSink = frameSink
        (events, eventSink) = AsyncStream.makeStream(of: PeerEvent.self, bufferingPolicy: .unbounded)
        super.init()
        let configuration = factory.configuration(ice: ice)
        guard let connection = factory.factory.peerConnection(
            with: configuration, constraints: factory.constraints(), delegate: self
        ) else { throw WebRTCPeerError.channelUnavailable }
        state.withLockUnchecked { $0.connection = connection }
        if mode == .lanes { startScheduler() }
    }

    var connection: RTCPeerConnection? { state.withLockUnchecked { $0.connection } }

    var isClosed: Bool { state.withLockUnchecked { $0.closed } }

    // MARK: Data path
    //
    // Lock rule: never call into libwebrtc while holding `state`. Its ObjC
    // objects proxy calls to the signaling or network thread and wait, and
    // those threads take `state` in the delegate callbacks.

    /// Creates the primary channel (the dialer, before its offer): `ctl`
    /// for lanes, `wg` for datagrams.
    func createPrimaryChannel() throws {
        guard let connection, !isClosed else { throw WebRTCPeerError.closed }
        let configuration = RTCDataChannelConfiguration()
        switch mode {
        case .lanes:
            configuration.isOrdered = true
        case .datagram:
            configuration.isOrdered = false
            configuration.maxRetransmits = 0
        }
        guard let channel = connection.dataChannel(forLabel: mode.primaryLabel, configuration: configuration) else {
            throw WebRTCPeerError.channelUnavailable
        }
        channel.delegate = self
        state.withLockUnchecked { state in
            state.control = channel
            state.entries[ObjectIdentifier(channel)] = PeerChannelEntry(channel: channel, label: nil)
        }
    }

    /// Queues one frame on its lane, split into messages of at most
    /// `maxMessageBytes`; the lane scheduler sends them (see
    /// WebRTCPeer+LaneScheduler). Reliable lanes suspend while their queue
    /// is over `laneBudget`; unordered and partial lanes drop instead.
    func send(_ frame: TransportFrame) async throws {
        let label = LaneLabel(lane: frame.lane)
        _ = try sendChannel(for: label)
        let reliable = frame.lane.reliability.isReliable
        if reliable { try await waitForRoom(label.label) }
        let accepted = try state.withLockUnchecked { state -> Bool in
            guard !state.closed else { throw WebRTCPeerError.closed }
            var queue = state.laneQueues[label.label] ?? LaneQueue(label: label)
            if !reliable, queue.queuedBytes + frame.bytes.count > limits.laneBudget { return false }
            let id = state.nextFrameID
            state.nextFrameID &+= 1
            queue.append(chunker.split(frame.bytes, reliable: reliable, id: id))
            state.laneQueues[label.label] = queue
            return true
        }
        if accepted { wakeSink.yield() }
    }

    func sendControl(_ message: CarrierControlMessage) -> Bool {
        guard mode == .lanes, let control = state.withLockUnchecked({ $0.closed ? nil : $0.control }),
              control.readyState == .open else { return false }
        return control.sendData(RTCDataBuffer(data: message.data, isBinary: false))
    }

    var sentCounts: [String: Int] { state.withLockUnchecked { $0.sentCounts } }

    /// Datagram mode: one message on `wg`, suspending while its buffer is
    /// above `highWater` (b3-webrtc-wg.md `DatagramUnderlay.send`).
    func sendDatagram(_ datagram: Data, highWater: UInt64) async throws {
        guard mode == .datagram, let channel = state.withLockUnchecked({ $0.closed ? nil : $0.control }) else {
            throw WebRTCPeerError.closed
        }
        try await waitOpen(channel)
        while channel.bufferedAmount > highWater {
            try await waitDrain(channel)
        }
        guard !isClosed else { throw WebRTCPeerError.closed }
        guard channel.sendData(RTCDataBuffer(data: datagram, isBinary: true)) else {
            throw isClosed ? WebRTCPeerError.closed : WebRTCPeerError.sendFailed
        }
    }

    /// Records the peer's `fin`; reports `.finSatisfied` once every lane has
    /// delivered the announced count.
    func expectFin(_ counts: [String: Int]) {
        let satisfied = state.withLockUnchecked { state -> Bool in
            state.finExpected = counts
            return Self.finSatisfied(&state)
        }
        if satisfied { eventSink.yield(.finSatisfied) }
    }

    private static func finSatisfied(_ state: inout State) -> Bool {
        guard !state.finReported, let expected = state.finExpected else { return false }
        for (label, count) in expected where state.receivedCounts[label, default: 0] < count { return false }
        state.finReported = true
        return true
    }

    private func sendChannel(for label: LaneLabel) throws -> RTCDataChannel {
        let existing = try state.withLockUnchecked { state -> RTCDataChannel? in
            guard !state.closed else { throw WebRTCPeerError.closed }
            return state.sendChannels[label.label]
        }
        if let existing { return existing }
        guard let connection else { throw WebRTCPeerError.closed }
        let configuration = RTCDataChannelConfiguration()
        switch label.lane.reliability {
        case .reliableOrdered:
            configuration.isOrdered = true
        case .unreliableUnordered:
            configuration.isOrdered = false
            configuration.maxRetransmits = 0
        case .partial:
            configuration.isOrdered = false
            configuration.maxPacketLifeTime = Int32(label.maxPacketLifeTimeMs ?? 1)
        }
        guard let created = connection.dataChannel(forLabel: label.label, configuration: configuration) else {
            throw WebRTCPeerError.channelUnavailable
        }
        created.delegate = self
        return state.withLockUnchecked { state in
            // A channel for this lane the peer opened meanwhile is fine to
            // keep reading; we send on whichever registered first.
            state.entries[ObjectIdentifier(created)] = PeerChannelEntry(channel: created, label: label)
            if let winner = state.sendChannels[label.label] { return winner }
            state.sendChannels[label.label] = created
            return created
        }
    }

    private func waitOpen(_ channel: RTCDataChannel) async throws {
        let id = ObjectIdentifier(channel)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let closed = state.withLockUnchecked { state -> Bool in
                guard !state.closed else { return true }
                state.openWaiters[id, default: []].append(continuation)
                return false
            }
            guard !closed else {
                continuation.resume(throwing: WebRTCPeerError.closed)
                return
            }
            // Re-check after registering: the open callback may have fired
            // before the waiter existed.
            switch channel.readyState {
            case .open: resumeWaiters(open: id)
            case .closing, .closed: failWaiters(id)
            default: break
            }
        }
    }

    private func waitDrain(_ channel: RTCDataChannel) async throws {
        let id = ObjectIdentifier(channel)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let (closed, lowWater) = state.withLockUnchecked { state -> (Bool, UInt64) in
                guard !state.closed else { return (true, 0) }
                state.drainWaiters[id, default: []].append(continuation)
                return (false, limits.lowWater)
            }
            guard !closed else {
                continuation.resume(throwing: WebRTCPeerError.closed)
                return
            }
            if channel.readyState != .open {
                failWaiters(id)
            } else if channel.bufferedAmount <= lowWater {
                resumeWaiters(drain: id)
            }
        }
    }

    private func resumeWaiters(open id: ObjectIdentifier) {
        let waiters = state.withLockUnchecked { $0.openWaiters.removeValue(forKey: id) ?? [] }
        for waiter in waiters { waiter.resume() }
    }

    private func resumeWaiters(drain id: ObjectIdentifier) {
        let waiters = state.withLockUnchecked { $0.drainWaiters.removeValue(forKey: id) ?? [] }
        for waiter in waiters { waiter.resume() }
    }

    private func failWaiters(_ id: ObjectIdentifier) {
        let waiters = state.withLockUnchecked { state in
            (state.openWaiters.removeValue(forKey: id) ?? []) + (state.drainWaiters.removeValue(forKey: id) ?? [])
        }
        for waiter in waiters { waiter.resume(throwing: WebRTCPeerError.channelUnavailable) }
    }

    // MARK: Callbacks from the delegates

    func registerRemote(_ channel: RTCDataChannel) {
        let isControl = channel.label == mode.primaryLabel
        let label = isControl || mode == .datagram ? nil : LaneLabel(label: channel.label)
        guard isControl || label != nil else {
            channel.close()
            return
        }
        channel.delegate = self
        let registered = state.withLockUnchecked { state -> Bool in
            guard !state.closed else { return false }
            state.entries[ObjectIdentifier(channel)] = PeerChannelEntry(channel: channel, label: label)
            if isControl {
                state.control = channel
            } else if let label, state.sendChannels[label.label] == nil {
                state.sendChannels[label.label] = channel
            }
            return true
        }
        if registered, isControl, channel.readyState == .open { eventSink.yield(.controlOpen) }
        if registered, !isControl { wakeSink.yield() }
    }

    func channelStateChanged(_ channel: RTCDataChannel) {
        let id = ObjectIdentifier(channel)
        let readyState = channel.readyState
        let (entry, closeNow) = state.withLockUnchecked { state -> (PeerChannelEntry?, Bool) in
            let entry = state.entries[id]
            if readyState == .closing || readyState == .closed,
               let label = entry?.label, state.sendChannels[label.label] === channel {
                state.sendChannels[label.label] = nil
            }
            return (entry, entry?.label == nil && readyState == .closed && state.closeOnControlClose)
        }
        switch readyState {
        case .open:
            resumeWaiters(open: id)
            wakeSink.yield()
        case .closing, .closed: failWaiters(id)
        default: break
        }
        guard let entry, entry.label == nil else { return }
        switch readyState {
        case .open:
            eventSink.yield(.controlOpen)
        case .closed:
            if closeNow { close() }
            eventSink.yield(.controlClosed)
        default:
            break
        }
    }

    func bufferedAmountChanged(_ channel: RTCDataChannel, amount: UInt64) {
        let id = ObjectIdentifier(channel)
        let waiters = state.withLockUnchecked { state -> [CheckedContinuation<Void, any Error>] in
            guard amount <= limits.lowWater else { return [] }
            return state.drainWaiters.removeValue(forKey: id) ?? []
        }
        for waiter in waiters { waiter.resume() }
        if amount <= limits.channelHighWater { wakeSink.yield() }
    }

    func received(_ data: Data, on channel: RTCDataChannel) {
        let id = ObjectIdentifier(channel)
        let maxFrame = TransportCapabilities.stream.maxFrameBytes
        let (entry, frame, satisfied) = state.withLockUnchecked { state -> (PeerChannelEntry?, Data?, Bool) in
            guard !state.closed, let entry = state.entries[id] else { return (nil, nil, false) }
            guard let label = entry.label else { return (entry, data, false) }
            if label.lane.reliability.isReliable { state.receivedBytes += data.count }
            var reassembly = state.reassembly[id] ?? MessageReassembly(maxFrameBytes: maxFrame)
            let frame = reassembly.receive(data)
            state.reassembly[id] = reassembly
            guard let frame, label.lane.reliability.isReliable else { return (entry, frame, false) }
            state.receivedCounts[label.label, default: 0] += 1
            return (entry, frame, Self.finSatisfied(&state))
        }
        guard let entry else { return }
        // Credit on every message, not only on completed frames: a frame
        // larger than the window would otherwise never complete.
        if entry.label != nil { creditIfDue() }
        guard let frame else { return }
        if let label = entry.label {
            frameSink.yield(.frame(TransportFrame(lane: label.lane, bytes: frame)))
        } else if mode == .datagram {
            frameSink.yield(.frame(TransportFrame(lane: PeerMode.datagramLane, bytes: frame)))
        } else if let message = CarrierControlMessage(data: frame) {
            if case let .credit(received) = message {
                credited(received)
            } else {
                eventSink.yield(.control(message))
            }
        }
        if satisfied { eventSink.yield(.finSatisfied) }
    }

    // MARK: Teardown

    /// After a remote `fin`: close as soon as the closer closes its side.
    func closeWhenControlCloses() {
        state.withLockUnchecked { $0.closeOnControlClose = true }
    }

    /// Closes the peer connection; pending sends fail. Idempotent. The
    /// close and the last release of every libwebrtc object run on a private
    /// queue: their teardown blocks on libwebrtc's threads, which must never
    /// stall Swift's cooperative pool.
    func close() {
        let taken = state.withLockUnchecked { state -> (RTCPeerConnection?, [PeerChannelEntry], [CheckedContinuation<Void, any Error>])? in
            guard !state.closed else { return nil }
            state.closed = true
            let waiters = state.openWaiters.values.flatMap { $0 } + state.drainWaiters.values.flatMap { $0 }
                + state.roomWaiters.values.flatMap { $0 }
            for waiter in state.flushWaiters { waiter.resume() }
            state.flushWaiters = []
            state.roomWaiters = [:]
            state.laneQueues = [:]
            let entries = Array(state.entries.values)
            let connection = state.connection
            state.openWaiters = [:]
            state.drainWaiters = [:]
            state.entries = [:]
            state.sendChannels = [:]
            state.control = nil
            state.connection = nil
            return (connection, entries, waiters)
        }
        guard let (connection, entries, waiters) = taken else { return }
        for waiter in waiters { waiter.resume(throwing: WebRTCPeerError.closed) }
        eventSink.finish()
        wakeSink.finish()
        let teardown = Teardown(connection: connection, entries: entries)
        Self.teardownQueue.async { teardown.run() }
    }

    // carve-out justification: libwebrtc teardown blocks on its threads and must
    // not run on the cooperative pool.
    private static let teardownQueue = DispatchQueue(label: "dev.cmux.link.webrtc.teardown")

    /// Carries libwebrtc objects to the teardown queue.
    private struct Teardown: @unchecked Sendable {
        var connection: RTCPeerConnection?
        var entries: [PeerChannelEntry]

        func run() {
            for entry in entries { entry.channel.delegate = nil }
            connection?.close()
        }
    }
}
