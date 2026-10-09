import CmuxLink
import Foundation

extension WireGuardLinkTransport {
    /// The only writer to the underlay. Sends one datagram at a time, always
    /// the most urgent: handshake and raw datagrams, close frames, acks, then
    /// lanes by priority (reliable before partial before unordered).
    func runPump() async {
        while phase != .closed {
            guard let underlay, hasQueuedWork else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if phase == .closed || (self.underlay != nil && hasQueuedWork) {
                        continuation.resume()
                    } else {
                        pumpWaiter = continuation
                    }
                }
                continue
            }
            guard let datagram = nextDatagram() else { continue }
            // A refused send is datagram loss; reliable lanes retransmit.
            try? await underlay.send(Data(datagram))
        }
    }

    var hasQueuedWork: Bool {
        !rawQueue.isEmpty || !controlQueue.isEmpty || !ackDirty.isEmpty
            || reliableQueues.values.contains { !$0.isEmpty } || messageQueues.values.contains { !$0.isEmpty }
    }

    /// The next encrypted datagram, or nil when the dequeued item vanished
    /// (acknowledged while queued, expired, or staged behind a handshake).
    func nextDatagram() -> [UInt8]? {
        if let raw = rawQueue.pop() { return raw }
        if let frame = controlQueue.pop() { return seal(frame.encode()) }
        if let lane = ackDirty.min(by: { $0.priority < $1.priority || ($0.priority == $1.priority && $0.byte < $1.byte) }) {
            ackDirty.remove(lane)
            guard let ack = receivers[lane]?.ack else { return nil }
            return seal(LaneFrame.ack(lane: lane, next: ack.next, sack: ack.sack, consumed: receiveCredit.advertise(lane)).encode())
        }
        let now = clock.now
        for priority in ChannelPriority.allCases {
            let reliable = LaneID(kind: .reliable, priority: priority)
            while var queue = reliableQueues[reliable], let seq = queue.pop() {
                reliableQueues[reliable] = queue
                if let frame = senders[reliable]?.transmit(seq, now: now) {
                    rearmTimer()
                    return seal(frame)
                }
            }
            for kind in [LaneID.Kind.partial, .unordered] {
                let lane = LaneID(kind: kind, priority: priority)
                while var queue = messageQueues[lane], let message = queue.pop() {
                    messageQueues[lane] = queue
                    if let lifetime = message.lifetime, now - message.enqueuedAt > lifetime { continue }
                    return seal(message.frame)
                }
            }
        }
        return nil
    }

    /// Wraps a lane frame in an overlay datagram and encrypts it. Extra
    /// datagrams the tunnel produced (a rekey initiation) go to the raw queue.
    func seal(_ laneFrame: [UInt8]) -> [UInt8]? {
        let packet = OverlayDatagram(source: localAddress, destination: remoteAddress, payload: laneFrame).encode()
        var output = tunnel.encapsulate(packet, now: clock.now)
        guard !output.datagrams.isEmpty else {
            rearmTimer()
            return nil
        }
        let first = output.datagrams.removeFirst()
        for extra in output.datagrams { rawQueue.push(extra) }
        if !output.datagrams.isEmpty { rearmTimer() }
        return first
    }
}
