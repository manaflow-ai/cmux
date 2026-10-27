import Darwin
import Foundation

extension LineTransport {
    /// What the transport's one lock guards: ids, waiters, deadlines, the close, and the stream-0 routing.
    struct State {
        var nextID: UInt64 = 1
        /// Requests waiting for their reply, by id and in send order.
        var pending = PendingRequests()
        /// Reply deadlines of the pending requests that have one, earliest first.
        var deadlines = DeadlineHeap()
        /// The deadline the connection's one timer is armed for; nil when it is not.
        var armedAt: Duration?
        var closed: TransportCloseReason?
        var sawShutdown = false
        /// Stream-0 events routed so far (raw events and `controlStreams`
        /// lines); responses capture it as their barrier.
        var eventCount: UInt64 = 0
        /// Streams the daemon writes in its reply FIFO (`session.events`).
        var controlStreams: Set<String> = []
        /// Gets resource API stream lines (`stream_item`, `stream_end`).
        var streamHandler: (@Sendable (_ streamID: String, _ line: Data) -> Void)?
        /// The attach streams this side minted (LineTransport+AttachStreams.swift).
        var attachStreams = AttachStreamTable()

        /// Takes every deadline due at `now` out and marks its request expired: what each one's
        /// `timedOut` needs. The timer is no longer armed (its fire called this).
        mutating func expireDue(at now: Duration) -> [Expired] {
            armedAt = nil
            var expired: [Expired] = []
            while let due = deadlines.popDue(at: now) {
                guard let entry = pending[due.id], case .reply(let cmd, let slot) = entry.waiter else { continue }
                pending.replace(id: due.id, with: PendingRequest(waiter: .expired(cmd: cmd), sent: nil))
                expired.append(Expired(cmd: cmd, slot: slot, sent: entry.sent, timeout: due.deadline.timeout))
            }
            return expired
        }

        /// The deadline to arm the timer for: the earliest one, unless the timer is armed at or before
        /// it already. Recorded as armed.
        mutating func nextArm() -> Duration? {
            guard let earliest = deadlines.first?.deadline.at else { return nil }
            if let armedAt, armedAt <= earliest { return nil }
            armedAt = earliest
            return earliest
        }
    }

    /// Reads the time since now on `clock` (the existential opened, so its instants stay typed).
    static func elapsedReader<C: Clock>(_ clock: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = clock.now
        return { start.duration(to: clock.now) }
    }

    /// Asks for ``socketBufferBytes`` each way; the kernel may round it up. A refusal keeps the default:
    /// the connection still works, with more reads.
    static func sizeBuffers(_ fd: Int32) {
        var bytes = Int32(clamping: socketBufferBytes)
        let size = socklen_t(MemoryLayout<Int32>.size)
        // SAFETY: setsockopt reads `size` bytes, MemoryLayout<Int32>.size, from `bytes`, an Int32 live for the call.
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bytes, size)
        // SAFETY: as above.
        _ = unsafe setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, size)
    }

    /// `fd`'s SO_SNDBUF and SO_RCVBUF as the kernel reports them (0 for one it does not report).
    static func bufferSizes(_ fd: Int32) -> (send: Int, receive: Int) {
        func size(_ option: Int32) -> Int {
            var value: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            // SAFETY: getsockopt writes at most `length` bytes, MemoryLayout<Int32>.size, into `value`, an Int32
            // live for the call, and writes the size it wrote back into `length`.
            let read = unsafe getsockopt(fd, SOL_SOCKET, option, &value, &length)
            return read == 0 ? Int(truncatingIfNeeded: value) : 0
        }
        return (send: size(SO_SNDBUF), receive: size(SO_RCVBUF))
    }
}
