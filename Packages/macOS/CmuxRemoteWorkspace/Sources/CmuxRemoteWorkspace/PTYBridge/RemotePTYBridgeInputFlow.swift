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
    private let maxWriteBytes: Int

    private var nextSeq: UInt64 = 1
    private var pendingWrites: [PendingWrite] = []
    private var pendingBytes = 0
    private var bufferedInput: [Data] = []
    private var bufferedBytes = 0
    private(set) var isPaused = false

    /// `maxWriteBytes` bounds a single `pty.write`: the daemon rejects RPC
    /// frames over 4 MiB before it can parse attachment identity, so a write
    /// must stay well under that after base64 (~4/3x) plus JSON overhead.
    init(
        maxPendingWrites: Int,
        maxPendingBytes: Int,
        seqAckEnabled: Bool,
        maxWriteBytes: Int = 256 * 1024
    ) {
        self.maxPendingWrites = max(1, maxPendingWrites)
        self.maxPendingBytes = max(1, maxPendingBytes)
        lowWatermarkWrites = max(0, maxPendingWrites / 2)
        lowWatermarkBytes = max(0, maxPendingBytes / 2)
        self.seqAckEnabled = seqAckEnabled
        self.maxWriteBytes = max(1, maxWriteBytes)
    }

    func enqueue(_ data: Data) -> DrainResult? {
        guard !data.isEmpty else {
            return DrainResult(writes: [], shouldResumeReads: false)
        }
        var writes: [Write] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: maxWriteBytes, limitedBy: data.endIndex) ?? data.endIndex
            let piece = Data(data[offset..<end])
            offset = end
            // Once a piece buffers, every later piece must buffer too or
            // bytes would reorder around the window boundary.
            if bufferedInput.isEmpty, let write = reserveWrite(for: piece) {
                writes.append(write)
                continue
            }
            guard bufferedBytes <= maxPendingBytes - piece.count else {
                return nil
            }
            bufferedInput.append(piece)
            bufferedBytes += piece.count
            isPaused = true
        }
        return DrainResult(writes: writes, shouldResumeReads: false)
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
        // An ack for a seq that was never sent is a protocol violation;
        // nil tells the session to tear down visibly instead of trusting it.
        guard seq < nextSeq else {
            return nil
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
