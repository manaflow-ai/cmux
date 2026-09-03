// Bounded FIFO handoff between the relay event pump and a CmxByteTransport
// consumer. Used instead of AsyncStream so the buffer has an explicit byte
// bound: a stalled consumer kills its own session (finish -> EOF -> redial
// with cursors) instead of growing process memory while terminal output
// streams in.

import Foundation

actor RelayByteQueue {
    /// Per-session buffer bound. Generous for RPC frames; a consumer that
    /// falls this far behind is stalled, not slow.
    static let maxBufferedBytes = 4 * 1024 * 1024

    private var buffer: [Data] = []
    private var bufferedBytes = 0
    private var waiter: CheckedContinuation<Data?, Never>?
    private var finished = false

    /// Enqueues bytes; on overflow the queue finishes (EOF to the consumer).
    func yield(_ data: Data) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: data)
            return
        }
        bufferedBytes += data.count
        if bufferedBytes > Self.maxBufferedBytes {
            finish()
            return
        }
        buffer.append(data)
    }

    func finish() {
        guard !finished else { return }
        finished = true
        buffer.removeAll()
        bufferedBytes = 0
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: nil)
        }
    }

    /// Single sequential consumer. Returns nil after finish().
    func next() async -> Data? {
        if !buffer.isEmpty {
            let data = buffer.removeFirst()
            bufferedBytes -= data.count
            return data
        }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}
