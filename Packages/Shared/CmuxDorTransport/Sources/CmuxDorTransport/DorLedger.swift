// Pure reliability bookkeeping for one leg: upload sequencing + resend
// buffering (pruned by relay `ackup`), download dedup + ack coalescing.
// Factored out of the DorLeg actor so the contract is unit-testable without
// sockets. State is per directed stream: a phone has exactly one stream each
// way (to/from its bound Mac); a Mac has one per phone leg id.

import Foundation

struct DorLedger: Sendable {
    enum DownloadResult: Sendable, Equatable {
        case accepted
        case duplicate
        case gap
    }

    struct OutboundFrame: Sendable {
        let destination: UInt32
        let seq: UInt64
        let encoded: Data
    }

    enum AckDecision: Sendable, Equatable {
        case none
        case ack(seq: UInt64, leg: UInt32?)
    }

    /// Resend-buffer caps. Beyond these the leg must surface `.reset`: the
    /// relay ring could not prove the gap either, so continuity is over.
    static let maxBufferedFrames = 512
    static let maxBufferedBytes = 4 * 1024 * 1024
    /// Ack coalescing: at most one ack per stream per this many frames…
    static let ackEveryFrames = 16
    /// …or per this interval, whichever comes first.
    static let ackInterval: TimeInterval = 0.1

    let role: DorLegRole

    // Upload state per destination key (a phone's single upload stream is "h").
    private var nextSeq: [String: UInt64] = [:]
    private var unacked: [String: [OutboundFrame]] = [:]
    private var bufferedBytes = 0

    // Download state per source key.
    private var lastReceived: [String: UInt64] = [:]
    private var unackedDownloads: [String: Int] = [:]
    private var lastAckAt: [String: TimeInterval] = [:]

    init(role: DorLegRole) {
        self.role = role
    }

    private func uploadKey(_ destination: UInt32) -> String {
        role == .phone ? "h" : String(destination)
    }

    private func downloadKey(_ source: UInt32) -> String {
        role == .phone ? "h" : String(source)
    }

    // MARK: upload

    /// Assign the next seq for a payload and record it for resend. Nil when
    /// the buffer is exhausted (the caller must reset the leg).
    mutating func recordUpload(payload: Data, destination: UInt32) -> OutboundFrame? {
        let key = uploadKey(destination)
        let seq = (nextSeq[key] ?? 0) + 1
        nextSeq[key] = seq
        let encoded = DorWire.encodeData(
            DorWire.DataFrame(legID: destination, seq: seq, payload: payload))
        let frame = OutboundFrame(destination: destination, seq: seq, encoded: encoded)
        unacked[key, default: []].append(frame)
        bufferedBytes += encoded.count
        if totalBufferedFrames > Self.maxBufferedFrames || bufferedBytes > Self.maxBufferedBytes {
            return nil
        }
        return frame
    }

    /// Relay confirmed ring-durability through `seq`: drop buffered frames.
    mutating func handleAckUp(seq: UInt64, leg: UInt32?) {
        let key = role == .phone ? "h" : String(leg ?? 0)
        guard var queue = unacked[key] else { return }
        while let first = queue.first, first.seq <= seq {
            bufferedBytes -= first.encoded.count
            queue.removeFirst()
        }
        unacked[key] = queue
    }

    /// Frames to retransmit after a resume, per-destination order preserved.
    func framesForResend() -> [OutboundFrame] {
        unacked.values.flatMap { $0 }.sorted { left, right in
            left.destination == right.destination
                ? left.seq < right.seq
                : left.destination < right.destination
        }
    }

    var totalBufferedFrames: Int {
        unacked.values.reduce(0) { $0 + $1.count }
    }

    // MARK: download

    /// Dedup an inbound frame. A forward gap is a continuity failure, not a
    /// frame that can be acknowledged safely.
    mutating func acceptDownload(source: UInt32, seq: UInt64) -> Bool {
        acceptDownloadResult(source: source, seq: seq) == .accepted
    }

    mutating func acceptDownloadResult(source: UInt32, seq: UInt64) -> DownloadResult {
        let key = downloadKey(source)
        let previous = lastReceived[key] ?? 0
        guard seq > previous else { return .duplicate }
        guard previous < UInt64.max, seq == previous + 1 else { return .gap }
        lastReceived[key] = seq
        unackedDownloads[key] = (unackedDownloads[key] ?? 0) + 1
        return .accepted
    }

    /// Whether an ack should be emitted now for this stream (coalesced).
    mutating func ackDecision(source: UInt32, now: TimeInterval) -> AckDecision {
        let key = downloadKey(source)
        guard let last = lastReceived[key] else { return .none }
        let pending = unackedDownloads[key] ?? 0
        guard pending > 0 else { return .none }
        let since = now - (lastAckAt[key] ?? 0)
        guard pending >= Self.ackEveryFrames || since >= Self.ackInterval else { return .none }
        unackedDownloads[key] = 0
        lastAckAt[key] = now
        return .ack(seq: last, leg: role == .host ? source : nil)
    }

    /// Acks that must flush regardless of coalescing (idle tick).
    mutating func flushAcks(now: TimeInterval) -> [AckDecision] {
        var out: [AckDecision] = []
        for (key, pending) in unackedDownloads where pending > 0 {
            guard let last = lastReceived[key] else { continue }
            unackedDownloads[key] = 0
            lastAckAt[key] = now
            out.append(.ack(seq: last, leg: role == .host ? UInt32(key) : nil))
        }
        return out
    }

    /// Resume parameters: last received seq (phone) / per-source map (Mac).
    var resumeAck: UInt64 {
        lastReceived["h"] ?? 0
    }

    var resumeAcks: [UInt32: UInt64] {
        var acks: [UInt32: UInt64] = [:]
        for (key, seq) in lastReceived {
            if let leg = UInt32(key) { acks[leg] = seq }
        }
        return acks
    }

    /// A fresh session (resume refused) restarts every stream: seqs restart
    /// at 1, dedup floors clear, buffered uploads drop (their E2E session
    /// died with the old leg).
    mutating func resetForFreshSession() {
        nextSeq = [:]
        unacked = [:]
        bufferedBytes = 0
        lastReceived = [:]
        unackedDownloads = [:]
        lastAckAt = [:]
    }
}
