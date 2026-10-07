/// The sending half of one reliable lane: numbered fragments kept until
/// acknowledged, a byte window, RTO and SACK-driven retransmission.
struct ReliableSender {
    struct Fragment {
        let frame: [UInt8]
        var sentAt: Duration?
        /// First transmission, for the dead-path check (retransmissions
        /// move `sentAt`, not this).
        var firstSentAt: Duration?
        var transmissions = 0
        var sacked = false
        /// Sitting in the transport's send queue.
        var queued = false
    }

    let lane: LaneID
    private(set) var fragments: [UInt32: Fragment] = [:]
    private(set) var bytesInFlight = 0
    private var nextSeq: UInt32 = 0
    /// Lowest sequence not yet cumulatively acknowledged.
    private(set) var base: UInt32 = 0

    init(lane: LaneID) {
        self.lane = lane
    }

    var isDrained: Bool { fragments.isEmpty }

    /// Splits `payload` into fragments of at most `maxPayload` bytes and
    /// returns their sequence numbers, in order, to queue.
    mutating func enqueue(_ payload: [UInt8], maxPayload: Int) -> [UInt32] {
        var seqs: [UInt32] = []
        var offset = 0
        repeat {
            let end = min(payload.count, offset + maxPayload)
            let frame = LaneFrame.reliable(
                lane: lane, seq: nextSeq, first: offset == 0, last: end == payload.count,
                payload: Array(payload[offset..<end])
            ).encode()
            fragments[nextSeq] = Fragment(frame: frame, queued: true)
            bytesInFlight += frame.count
            seqs.append(nextSeq)
            nextSeq += 1
            offset = end
        } while offset < payload.count
        return seqs
    }

    /// Takes a queued fragment for the wire, or nil when it was acknowledged
    /// while queued.
    mutating func transmit(_ seq: UInt32, now: Duration) -> [UInt8]? {
        guard var fragment = fragments[seq] else { return nil }
        fragment.queued = false
        guard !fragment.sacked else {
            fragments[seq] = fragment
            return nil
        }
        fragment.sentAt = now
        if fragment.firstSentAt == nil { fragment.firstSentAt = now }
        fragment.transmissions += 1
        fragments[seq] = fragment
        return fragment.frame
    }

    /// Applies an ack. Returns an RTT sample (a fragment sent once) and the
    /// fragments to retransmit at once (three later fragments arrived).
    mutating func acknowledge(next: UInt32, sack: UInt64, now: Duration, smoothedRTT: Duration?) -> (rtt: Duration?, retransmit: [UInt32]) {
        var sample: Duration?
        // An ack beyond what was ever sent is a protocol error; ignore it.
        guard next <= nextSeq else { return (nil, []) }
        if next > base {
            for seq in base..<next {
                guard let fragment = fragments.removeValue(forKey: seq) else { continue }
                bytesInFlight -= fragment.frame.count
                if fragment.transmissions == 1, let sentAt = fragment.sentAt { sample = now - sentAt }
            }
            base = next
        }
        var highestSacked: UInt32?
        for bit in 0..<64 where sack & (1 << UInt64(bit)) != 0 {
            let seq = next &+ 1 &+ UInt32(bit)
            guard var fragment = fragments[seq] else { continue }
            if !fragment.sacked {
                fragment.sacked = true
                fragments[seq] = fragment
                if fragment.transmissions == 1, let sentAt = fragment.sentAt, sample == nil { sample = now - sentAt }
            }
            highestSacked = seq
        }
        var retransmit: [UInt32] = []
        if let highestSacked, highestSacked >= next {
            let threshold = smoothedRTT ?? .milliseconds(50)
            for seq in next..<highestSacked {
                guard var fragment = fragments[seq], !fragment.sacked, !fragment.queued, let sentAt = fragment.sentAt else { continue }
                let later = (seq + 1...highestSacked).reduce(0) { $0 + ((fragments[$1]?.sacked ?? false) ? 1 : 0) }
                guard later >= 3, now - sentAt >= threshold else { continue }
                fragment.queued = true
                fragments[seq] = fragment
                retransmit.append(seq)
            }
        }
        return (sample, retransmit)
    }

    /// Earliest RTO expiry among sent, unacknowledged fragments.
    func earliestDeadline(timeout: Duration) -> Duration? {
        fragments.values.compactMap { fragment -> Duration? in
            guard !fragment.sacked, !fragment.queued, let sentAt = fragment.sentAt else { return nil }
            return sentAt + timeout
        }.min()
    }

    /// Oldest first-transmission time still unacknowledged (dead-path check).
    func oldestSend() -> Duration? {
        fragments[base]?.firstSentAt
    }

    /// Marks every fragment whose RTO expired for retransmission.
    mutating func expired(now: Duration, timeout: Duration) -> [UInt32] {
        var seqs: [UInt32] = []
        for (seq, fragment) in fragments where !fragment.sacked && !fragment.queued {
            guard let sentAt = fragment.sentAt, sentAt + timeout <= now else { continue }
            fragments[seq]?.queued = true
            seqs.append(seq)
        }
        return seqs.sorted()
    }

    /// Requeues every unacknowledged fragment (after the underlay changed).
    mutating func requeueAll() -> [UInt32] {
        var seqs: [UInt32] = []
        for (seq, fragment) in fragments where !fragment.sacked && !fragment.queued {
            fragments[seq]?.queued = true
            seqs.append(seq)
        }
        return seqs.sorted()
    }
}
