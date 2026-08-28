// Pure reliability bookkeeping for one leg: upload sequencing + resend
// buffering (pruned by relay `ackup`), download dedup + ack coalescing.
// Factored out of the DotLeg actor so the contract is unit-testable without
// sockets. All state is per-stream: the phone has one stream each way ("h");
// the host has one per phone leg id.

import Foundation

struct DotLegLedger: Sendable {
    struct OutboundFrame: Sendable {
        let destination: UInt32
        let seq: UInt64
        let encoded: Data
    }

    enum AckDecision: Sendable, Equatable {
        case none
        case ack(seq: UInt64, leg: UInt32?)
    }

    /// Resend buffer caps: beyond this the leg must surface `.reset` (the
    /// relay ring would not be able to prove the gap anyway).
    static let maxBufferedFrames = 512
    static let maxBufferedBytes = 4 * 1024 * 1024
    /// Ack coalescing: at most one ack per stream per this many frames…
    static let ackEveryFrames = 16
    /// …or per this interval, whichever comes first.
    static let ackInterval: TimeInterval = 0.1

    let role: DotLegRole

    // Upload state per destination key ("h" for phone uploads).
    private var nextSeq: [String: UInt64] = [:]
    private var unacked: [String: [OutboundFrame]] = [:]
    private var bufferedBytes = 0

    // Download state per source key.
    private var lastReceived: [String: UInt64] = [:]
    private var unackedDownloads: [String: Int] = [:]
    private var lastAckAt: [String: TimeInterval] = [:]

    init(role: DotLegRole) {
        self.role = role
    }

    private func uploadKey(_ destination: UInt32) -> String {
        role == .phone ? "h" : String(destination)
    }

    private func downloadKey(_ source: UInt32) -> String {
        role == .phone ? "h" : String(source)
    }

    // MARK: upload

    /// Assign the next seq for a payload and record it for resend. Returns
    /// nil when the buffer is exhausted (caller must reset the leg).
    mutating func recordUpload(payload: Data, destination: UInt32) -> OutboundFrame? {
        let key = uploadKey(destination)
        let seq = (nextSeq[key] ?? 0) + 1
        nextSeq[key] = seq
        let encoded = DotWire.encodeData(
            DotWire.DataFrame(legID: destination, seq: seq, payload: payload))
        let frame = OutboundFrame(destination: destination, seq: seq, encoded: encoded)
        var queue = unacked[key] ?? []
        queue.append(frame)
        unacked[key] = queue
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

    /// Frames to retransmit after a resume, oldest first, all destinations.
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

    var totalBufferedBytes: Int {
        bufferedBytes
    }

    // MARK: download

    /// Dedup an inbound frame; returns false when it is a replay the caller
    /// must drop. After a process-local gap (relay re-init), any higher seq
    /// is accepted — receivers tolerate forward jumps, never backwards.
    mutating func acceptDownload(source: UInt32, seq: UInt64) -> Bool {
        let key = downloadKey(source)
        let last = lastReceived[key] ?? 0
        guard seq > last else { return false }
        lastReceived[key] = seq
        unackedDownloads[key] = (unackedDownloads[key] ?? 0) + 1
        return true
    }

    /// Whether an ack should be emitted now for this stream (coalesced).
    mutating func ackDecision(source: UInt32, now: TimeInterval) -> AckDecision {
        let key = downloadKey(source)
        guard let last = lastReceived[key], (unackedDownloads[key] ?? 0) > 0 else { return .none }
        let pending = unackedDownloads[key] ?? 0
        let since = now - (lastAckAt[key] ?? 0)
        guard pending >= Self.ackEveryFrames || since >= Self.ackInterval else { return .none }
        unackedDownloads[key] = 0
        lastAckAt[key] = now
        return .ack(seq: last, leg: role == .host ? source : nil)
    }

    /// Acks that must flush regardless of coalescing (idle tick / pre-sleep).
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

    /// Resume parameters: last received seq (phone) / per-source map (host).
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
    /// at 1, dedup floors clear, buffered uploads are dropped (their session
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
