import Foundation

// MARK: - Queues

/// The priority FIFOs, the half-sent tail and the drain bookkeeping behind ``FrameWriter``'s lock.
extension FrameWriter {
    struct Message {
        let bytes: Data
        let fds: [Int32]
    }

    /// One drain step: messages in wire order; `fds` go with the first byte.
    struct Batch {
        var messages: [Data]
        let fds: [Int32]
        var byteCount: Int

        func joined() -> Data {
            var data = Data(capacity: byteCount)
            for message in messages { data.append(message) }
            return data
        }
    }

    /// One priority's FIFO: popped slots are cleared at once, so a sent message's bytes are not retained.
    struct Lane {
        private var slots: [Message?] = []
        private var head = 0

        var first: Message? { head < slots.count ? slots[head] : nil }

        mutating func append(_ message: Message) {
            slots.append(message)
        }

        mutating func popFirst() -> Message? {
            guard head < slots.count else { return nil }
            let message = slots[head]
            slots[head] = nil
            head += 1
            if head == slots.count {
                slots.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64, head * 2 >= slots.count {
                slots.removeFirst(head)
                head = 0
            }
            return message
        }

        /// Empties the FIFO; returns the descriptors of the dropped messages.
        mutating func removeAll() -> [Int32] {
            let fds = slots[head...].flatMap { $0?.fds ?? [] }
            slots.removeAll()
            head = 0
            return fds
        }
    }

    struct State {
        /// Indexed by ``MethodPriority/rawValue``: input, control, bulk, background.
        private var lanes = [Lane](repeating: Lane(), count: MethodPriority.allCases.count)
        private(set) var queuedBytes = 0
        var draining = false
        /// A drain step is sending: nothing is written inline until it ends.
        var inFlight = false
        /// The tail of a message an inline write began: the next drain step, before every FIFO.
        var rest: Message?
        /// Times the drain queue was woken (``FrameWriter/queueHops``).
        private(set) var drainStarts = 0
        var closed = false
        var failure: Failure?

        /// Whether a message of `priority` may be sent inline now: no drain step is sending, no message is half
        /// sent, and no message of `priority` or higher waits (lower ones it passes anyway).
        func mayWriteInline(_ priority: MethodPriority) -> Bool {
            guard !inFlight, rest == nil else { return false }
            return MethodPriority.allCases.allSatisfy { other in
                other.rawValue > priority.rawValue || lanes[Int(other.rawValue)].first == nil
            }
        }

        /// Marks the drain running; true when the caller must start it.
        mutating func startDrain() -> Bool {
            guard !draining else { return false }
            draining = true
            drainStarts += 1
            return true
        }

        mutating func append(_ message: Message, priority: MethodPriority) {
            lanes[Int(priority.rawValue)].append(message)
            queuedBytes += message.bytes.count
        }

        /// The next drain step: the head of the highest non-empty FIFO. When that head is input or control, the
        /// following input and control heads join it in priority order while they fit in `budget`, stopping at a
        /// message with descriptors (its descriptors must ride its own first byte). A bulk or background head is
        /// sent alone: one chunk is the preemption boundary (p05-ipc.md section 3.2). nil, and draining ends,
        /// when there is nothing to send.
        mutating func takeBatch(budget: Int) -> Batch? {
            guard !closed, failure == nil else {
                draining = false
                return nil
            }
            if let tail = rest {
                rest = nil
                inFlight = true
                return Batch(messages: [tail.bytes], fds: tail.fds, byteCount: tail.bytes.count)
            }
            guard let first = popHighest() else {
                draining = false
                return nil
            }
            inFlight = true
            var batch = Batch(messages: [first.message.bytes], fds: first.message.fds,
                              byteCount: first.message.bytes.count)
            guard Self.joins(first.priority) else {
                queuedBytes -= batch.byteCount
                return batch
            }
            while let head = peekHighest(), Self.joins(head.priority), head.message.fds.isEmpty,
                  batch.byteCount + head.message.bytes.count <= budget {
                let next = head.message
                _ = popHighest()
                batch.messages.append(next.bytes)
                batch.byteCount += next.bytes.count
            }
            queuedBytes -= batch.byteCount
            return batch
        }

        mutating func removeAll() -> [Int32] {
            queuedBytes = 0
            var fds: [Int32] = rest?.fds ?? []
            rest = nil
            for index in lanes.indices { fds += lanes[index].removeAll() }
            return fds
        }

        /// Whether a message of `priority` may share a send with other waiting messages: only input and control,
        /// which are small; bulk and background are cut at BULK_FRAME_MAX and each chunk is its own step.
        private static func joins(_ priority: MethodPriority) -> Bool {
            switch priority {
            case .input, .control: true
            case .bulk, .background: false
            }
        }

        private func peekHighest() -> (message: Message, priority: MethodPriority)? {
            for priority in MethodPriority.allCases {
                if let message = lanes[Int(priority.rawValue)].first { return (message, priority) }
            }
            return nil
        }

        private mutating func popHighest() -> (message: Message, priority: MethodPriority)? {
            for priority in MethodPriority.allCases {
                if let message = lanes[Int(priority.rawValue)].popFirst() { return (message, priority) }
            }
            return nil
        }
    }
}
