/// The session's send queues: control frames first, then coalesced acks,
/// then data strictly by channel priority (input > control > render > media
/// > bulk). FIFO inside a priority, so a channel's close follows its data.
struct OutboundQueue: Sendable {
    enum Next: Sendable {
        case item(OutboundItem)
        /// Send the latest cumulative ack of this channel.
        case ack(UInt32)
    }

    private var control: [OutboundItem] = []
    private var ackOrder: [UInt32] = []
    private var ackSet: Set<UInt32> = []
    private var byPriority: [[OutboundItem]] = Array(repeating: [], count: ChannelPriority.allCases.count)

    var isEmpty: Bool {
        control.isEmpty && ackOrder.isEmpty && byPriority.allSatisfy(\.isEmpty)
    }

    mutating func enqueueControl(_ item: OutboundItem) {
        control.append(item)
    }

    mutating func enqueue(_ item: OutboundItem, priority: ChannelPriority) {
        byPriority[priority.rawValue].append(item)
    }

    mutating func markAck(_ channel: UInt32) {
        if ackSet.insert(channel).inserted { ackOrder.append(channel) }
    }

    /// Drops the oldest queued item that counts against `channel`'s budget.
    /// Returns its byte count, or nil when nothing was queued.
    mutating func dropOldest(channel: UInt32, priority: ChannelPriority) -> Int? {
        guard let index = byPriority[priority.rawValue].firstIndex(where: { $0.budgetChannel == channel }) else {
            return nil
        }
        return byPriority[priority.rawValue].remove(at: index).bytes
    }

    /// The next frame to send. `expired` receives partial items dropped for
    /// age so the session can release their budget.
    mutating func dequeue(now: Duration, expired: (OutboundItem) -> Void) -> Next? {
        if !control.isEmpty { return .item(control.removeFirst()) }
        if !ackOrder.isEmpty {
            let channel = ackOrder.removeFirst()
            ackSet.remove(channel)
            return .ack(channel)
        }
        for priority in byPriority.indices {
            while !byPriority[priority].isEmpty {
                let item = byPriority[priority].removeFirst()
                if let lifetime = item.lifetime, now - item.enqueuedAt > lifetime {
                    expired(item)
                    continue
                }
                return .item(item)
            }
        }
        return nil
    }

    mutating func removeAll() {
        self = OutboundQueue()
    }
}
