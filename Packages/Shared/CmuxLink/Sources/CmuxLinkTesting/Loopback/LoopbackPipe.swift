import CmuxLink

/// An in-process connection between two `LoopbackTransport`s (side 0 is the
/// dialer, side 1 the host). With `NetworkConditions` it delays, jitters,
/// loses and throttles frames, keeping reliable-ordered lanes in order.
actor LoopbackPipe {
    private struct InFlight {
        let frame: TransportFrame
        let to: Int
        var ready = false
    }

    private struct LaneKey: Hashable {
        let to: Int
        let lane: TransportLane
    }

    private(set) var path: LinkPath
    private let inboxes: [TransportInbox]
    private var conditions: NetworkConditions?
    private let clock: LinkClock
    private let maxFrameBytes: Int
    private var generator: SeededGenerator
    private var closed = false
    /// A graceful close waits for in-flight reliable frames.
    private var closingSide: Int?
    private var nextSeq: UInt64 = 0
    private var inFlight: [UInt64: InFlight] = [:]
    private var orderedLanes: [LaneKey: [UInt64]] = [:]
    private var lastDeliveryAt: [LaneKey: Duration] = [:]
    private var linkFreeAt: [Duration] = [.zero, .zero]
    private var tracks: [LoopbackMediaTrack] = []
    /// Reliable bytes scheduled but not yet delivered, per receiving side.
    private var inFlightReliableBytes = [0, 0]
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        path: LinkPath,
        inboxes: [TransportInbox],
        conditions: NetworkConditions?,
        clock: LinkClock,
        maxFrameBytes: Int
    ) {
        self.path = path
        self.inboxes = inboxes
        self.conditions = conditions
        self.clock = clock
        self.maxFrameBytes = maxFrameBytes
        self.generator = SeededGenerator(seed: conditions?.seed ?? 1)
    }

    var isClosed: Bool { closed }

    func setConditions(_ conditions: NetworkConditions?) {
        self.conditions = conditions
    }

    func send(_ frame: TransportFrame, from side: Int) async throws {
        guard !closed, closingSide == nil else { throw LoopbackError.closed }
        guard frame.bytes.count <= maxFrameBytes else { throw LoopbackError.frameTooLarge(frame.bytes.count) }
        let to = 1 - side
        // Back-pressure: a receiver that stopped reading suspends reliable
        // sends; frames still in flight count against its room.
        while frame.lane.reliability.isReliable {
            if !inboxes[to].hasRoom {
                await inboxes[to].waitForRoom()
            } else if inFlightReliableBytes[to] >= inboxes[to].limits.reliableBytes {
                await withCheckedContinuation { releaseWaiters.append($0) }
            } else {
                break
            }
            guard !closed, closingSide == nil else { throw LoopbackError.closed }
        }
        guard let conditions else {
            deliver(frame, to: to)
            return
        }
        if let rate = conditions.bytesPerSecond, rate > 0 {
            let now = clock.now
            let transmit = Duration.seconds(Double(frame.bytes.count) / Double(rate))
            let start = max(now, linkFreeAt[side])
            linkFreeAt[side] = start + transmit
            let wait = start + transmit - now
            if wait > .zero { try await clock.sleep(for: wait) }
            guard !closed else { throw LoopbackError.closed }
        }
        schedule(frame, to: to, conditions: conditions)
    }

    private func schedule(_ frame: TransportFrame, to: Int, conditions: NetworkConditions) {
        let reliable = frame.lane.reliability.isReliable
        var delay = conditions.latency
        if conditions.jitter > .zero {
            delay += conditions.jitter * generator.unit()
        }
        if conditions.loss > 0, generator.unit() < conditions.loss {
            guard reliable else { return }
            // A reliable carrier retransmits: model the recovery as delay.
            delay += conditions.latency * 2 + .milliseconds(1)
        }
        let seq = nextSeq
        nextSeq += 1
        inFlight[seq] = InFlight(frame: frame, to: to)
        let key = LaneKey(to: to, lane: frame.lane)
        let now = clock.now
        var deliverAt = now + delay
        if reliable {
            inFlightReliableBytes[to] += frame.bytes.count
            orderedLanes[key, default: []].append(seq)
            deliverAt = max(deliverAt, lastDeliveryAt[key] ?? .zero)
            lastDeliveryAt[key] = deliverAt
        }
        let wait = deliverAt - now
        if wait <= .zero {
            release(seq)
            return
        }
        let clock = clock
        Task { [weak self] in
            try? await clock.sleep(for: wait)
            await self?.release(seq)
        }
    }

    private func release(_ seq: UInt64) {
        guard var item = inFlight[seq] else { return }
        guard !closed else {
            inFlight[seq] = nil
            return
        }
        guard item.frame.lane.reliability.isReliable else {
            inFlight[seq] = nil
            deliver(item.frame, to: item.to)
            return
        }
        item.ready = true
        inFlight[seq] = item
        let key = LaneKey(to: item.to, lane: item.frame.lane)
        while let head = orderedLanes[key]?.first, let ready = inFlight[head], ready.ready {
            orderedLanes[key]?.removeFirst()
            inFlight[head] = nil
            inFlightReliableBytes[ready.to] -= ready.frame.bytes.count
            deliver(ready.frame, to: ready.to)
        }
        resumeReleaseWaiters()
        if let side = closingSide, inFlight.isEmpty { close(from: side) }
    }

    private func resumeReleaseWaiters() {
        let waiters = releaseWaiters
        releaseWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func deliver(_ frame: TransportFrame, to: Int) {
        if inboxes[to].yield(.frame(frame)) == .overflow { drop("receive buffer overflow") }
    }

    func publishMediaTrack(_ descriptor: MediaTrackDescriptor, from side: Int) throws -> MediaTrackHandle {
        guard !closed else { throw LoopbackError.closed }
        let backing = LoopbackMediaTrack()
        tracks.append(backing)
        inboxes[1 - side].yield(.mediaTrack(MediaTrackHandle(descriptor: descriptor, backing: backing)))
        return MediaTrackHandle(descriptor: descriptor, backing: backing)
    }

    /// Moves the live pipe to another path without dropping it.
    func changePath(to kind: PathKind) {
        guard !closed else { return }
        path = LinkPath(kind: kind, carrier: path.carrier)
        for inbox in inboxes { inbox.yield(.pathChanged(path)) }
    }

    func reportRTT(_ rtt: Duration) {
        guard !closed else { return }
        for inbox in inboxes { inbox.yield(.rtt(rtt)) }
    }

    func reportHealth(_ health: LinkHealth) {
        guard !closed else { return }
        for inbox in inboxes { inbox.yield(.health(health)) }
    }

    func close(from side: Int) {
        guard !closed else { return }
        let reliablePending = inFlight.values.contains { $0.frame.lane.reliability.isReliable }
        if reliablePending {
            closingSide = side
            inFlight = inFlight.filter { $0.value.frame.lane.reliability.isReliable }
            return
        }
        end(reasons: side == 0 ? [.local, .remote] : [.remote, .local])
    }

    /// The path died under both ends.
    func drop(_ message: String) {
        guard !closed else { return }
        end(reasons: [.pathLost(message), .pathLost(message)])
    }

    private func end(reasons: [TransportCloseReason]) {
        closed = true
        inFlight.removeAll()
        orderedLanes.removeAll()
        inFlightReliableBytes = [0, 0]
        resumeReleaseWaiters()
        for (index, inbox) in inboxes.enumerated() {
            inbox.yield(.closed(reasons[index]))
            inbox.finish()
        }
        let ending = tracks
        tracks.removeAll()
        Task { for track in ending { await track.stop() } }
    }
}
