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
        var lowWater: UInt64 = 0
        var closeOnControlClose = false
    }

    let state = OSAllocatedUnfairLock(uncheckedState: State())
    let factory: WebRTCFactory
    /// Driver events.
    let events: AsyncStream<PeerEvent>
    let eventSink: AsyncStream<PeerEvent>.Continuation
    /// Frames for the transport's event stream.
    let frameSink: AsyncStream<TransportEvent>.Continuation

    init(
        factory: WebRTCFactory,
        ice: ICEConfiguration,
        lowWater: UInt64,
        frameSink: AsyncStream<TransportEvent>.Continuation
    ) throws {
        self.factory = factory
        self.frameSink = frameSink
        (events, eventSink) = AsyncStream.makeStream(of: PeerEvent.self, bufferingPolicy: .unbounded)
        super.init()
        let configuration = factory.configuration(ice: ice)
        guard let connection = factory.factory.peerConnection(
            with: configuration, constraints: factory.constraints(), delegate: self
        ) else { throw WebRTCPeerError.channelUnavailable }
        state.withLockUnchecked {
            $0.connection = connection
            $0.lowWater = lowWater
        }
    }

    var connection: RTCPeerConnection? { state.withLockUnchecked { $0.connection } }

    var isClosed: Bool { state.withLockUnchecked { $0.closed } }

    // MARK: Data path
    //
    // Lock rule: never call into libwebrtc while holding `state`. Its ObjC
    // objects proxy calls to the signaling or network thread and wait, and
    // those threads take `state` in the delegate callbacks.

    /// Creates the carrier control channel (the dialer, before its offer).
    func createControlChannel() throws {
        guard let connection, !isClosed else { throw WebRTCPeerError.closed }
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = true
        guard let channel = connection.dataChannel(forLabel: LaneLabel.control, configuration: configuration) else {
            throw WebRTCPeerError.channelUnavailable
        }
        channel.delegate = self
        state.withLockUnchecked { state in
            state.control = channel
            state.entries[ObjectIdentifier(channel)] = PeerChannelEntry(channel: channel, label: nil)
        }
    }

    /// Sends one frame on its lane's channel, creating the channel on first
    /// use. Reliable lanes wait for the channel to open and for buffer room;
    /// unreliable lanes drop when the buffer is above `highWater`.
    func send(_ frame: TransportFrame, highWater: UInt64) async throws {
        let label = LaneLabel(lane: frame.lane)
        let channel = try sendChannel(for: label)
        try await waitOpen(channel)
        let reliable = frame.lane.reliability.isReliable
        if reliable {
            while channel.bufferedAmount > highWater {
                try await waitDrain(channel)
            }
        } else if channel.bufferedAmount > highWater {
            return
        }
        guard !isClosed else { throw WebRTCPeerError.closed }
        guard channel.sendData(RTCDataBuffer(data: frame.bytes, isBinary: true)) else {
            throw isClosed ? WebRTCPeerError.closed : WebRTCPeerError.sendFailed
        }
        if reliable { state.withLockUnchecked { $0.sentCounts[label.label, default: 0] += 1 } }
    }

    func sendControl(_ message: CarrierControlMessage) -> Bool {
        guard let control = state.withLockUnchecked({ $0.closed ? nil : $0.control }),
              control.readyState == .open else { return false }
        return control.sendData(RTCDataBuffer(data: message.data, isBinary: false))
    }

    var sentCounts: [String: Int] { state.withLockUnchecked { $0.sentCounts } }

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
                return (false, state.lowWater)
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
        let isControl = channel.label == LaneLabel.control
        let label = isControl ? nil : LaneLabel(label: channel.label)
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
        case .open: resumeWaiters(open: id)
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
            guard amount <= state.lowWater else { return [] }
            return state.drainWaiters.removeValue(forKey: id) ?? []
        }
        for waiter in waiters { waiter.resume() }
    }

    func received(_ data: Data, on channel: RTCDataChannel) {
        let (entry, satisfied) = state.withLockUnchecked { state -> (PeerChannelEntry?, Bool) in
            guard !state.closed, let entry = state.entries[ObjectIdentifier(channel)] else { return (nil, false) }
            guard let label = entry.label, label.lane.reliability.isReliable else { return (entry, false) }
            state.receivedCounts[label.label, default: 0] += 1
            return (entry, Self.finSatisfied(&state))
        }
        guard let entry else { return }
        if let label = entry.label {
            frameSink.yield(.frame(TransportFrame(lane: label.lane, bytes: data)))
        } else if let message = CarrierControlMessage(data: data) {
            eventSink.yield(.control(message))
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
        let teardown = Teardown(connection: connection, entries: entries)
        Self.teardownQueue.async { teardown.run() }
    }

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
