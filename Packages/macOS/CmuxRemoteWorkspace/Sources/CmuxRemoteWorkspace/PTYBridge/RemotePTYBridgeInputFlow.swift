internal import Foundation

/// Queue-confined PTY input flow control for one bridge attachment.
final class RemotePTYBridgeInputFlow {
    struct Write {
        let data: Data
        let seq: UInt64?
    }

    struct DrainResult {
        let writes: [Write]
        let shouldResumeReads: Bool
    }

    private struct PendingWrite {
        let seq: UInt64?
        let bytes: Int
    }

    private let maxPendingWrites: Int
    private let maxPendingBytes: Int
    private let lowWatermarkWrites: Int
    private let lowWatermarkBytes: Int
    private let seqAckEnabled: Bool

    private var nextSeq: UInt64 = 1
    private var pendingWrites: [PendingWrite] = []
    private var pendingBytes = 0
    private var bufferedInput: [Data] = []
    private var bufferedBytes = 0
    private(set) var isPaused = false

    init(maxPendingWrites: Int, maxPendingBytes: Int, seqAckEnabled: Bool) {
        self.maxPendingWrites = max(1, maxPendingWrites)
        self.maxPendingBytes = max(1, maxPendingBytes)
        lowWatermarkWrites = max(0, maxPendingWrites / 2)
        lowWatermarkBytes = max(0, maxPendingBytes / 2)
        self.seqAckEnabled = seqAckEnabled
    }

    func enqueue(_ data: Data) -> DrainResult? {
        guard !data.isEmpty else {
            return DrainResult(writes: [], shouldResumeReads: false)
        }
        if let write = reserveWrite(for: data) {
            return DrainResult(writes: [write], shouldResumeReads: false)
        }
        guard bufferedBytes <= maxPendingBytes - data.count else {
            return nil
        }
        bufferedInput.append(data)
        bufferedBytes += data.count
        isPaused = true
        return DrainResult(writes: [], shouldResumeReads: false)
    }

    func complete(_ write: Write, error: (any Error)?) -> DrainResult? {
        if error != nil {
            return nil
        }
        guard !seqAckEnabled else {
            return DrainResult(writes: [], shouldResumeReads: false)
        }
        drainCompletedWrite(seq: write.seq, bytes: write.data.count)
        return flushBufferedInput()
    }

    func acknowledge(upTo seq: UInt64) -> DrainResult? {
        guard seqAckEnabled else {
            return DrainResult(writes: [], shouldResumeReads: false)
        }
        while let first = pendingWrites.first,
              let pendingSeq = first.seq,
              pendingSeq <= seq {
            pendingBytes = max(0, pendingBytes - first.bytes)
            pendingWrites.removeFirst()
        }
        return flushBufferedInput()
    }

    func reset() {
        pendingWrites.removeAll(keepingCapacity: false)
        pendingBytes = 0
        bufferedInput.removeAll(keepingCapacity: false)
        bufferedBytes = 0
        isPaused = false
    }

    private func reserveWrite(for data: Data) -> Write? {
        guard pendingWrites.count < maxPendingWrites,
              pendingBytes <= maxPendingBytes - data.count else {
            return nil
        }
        let seq = seqAckEnabled ? nextSeq : nil
        if seqAckEnabled {
            nextSeq += 1
        }
        pendingWrites.append(PendingWrite(seq: seq, bytes: data.count))
        pendingBytes += data.count
        return Write(data: data, seq: seq)
    }

    private func drainCompletedWrite(seq: UInt64?, bytes: Int) {
        if let index = pendingWrites.firstIndex(where: { $0.seq == seq && $0.bytes == bytes }) {
            pendingWrites.remove(at: index)
        } else if !pendingWrites.isEmpty {
            pendingWrites.removeFirst()
        }
        pendingBytes = max(0, pendingBytes - bytes)
    }

    private func flushBufferedInput() -> DrainResult {
        var writes: [Write] = []
        while let first = bufferedInput.first,
              let write = reserveWrite(for: first) {
            bufferedInput.removeFirst()
            bufferedBytes = max(0, bufferedBytes - first.count)
            writes.append(write)
        }
        let belowLowWatermark = pendingWrites.count <= lowWatermarkWrites &&
            pendingBytes <= lowWatermarkBytes
        let shouldResume = isPaused && bufferedInput.isEmpty && belowLowWatermark
        if shouldResume {
            isPaused = false
        }
        return DrainResult(writes: writes, shouldResumeReads: shouldResume)
    }
}
