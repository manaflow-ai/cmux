public struct VNCControlMessageQueue: Equatable, Sendable {
    public private(set) var messages: [VNCControlMessage] = []
    public var maxMessages: Int

    public init(maxMessages: Int) {
        self.maxMessages = max(0, maxMessages)
    }

    public var isEmpty: Bool {
        messages.isEmpty
    }

    public mutating func append(_ message: VNCControlMessage) -> Bool {
        if message.isCoalesciblePointerMove,
           let lastIndex = messages.indices.last,
           messages[lastIndex].isCoalesciblePointerMove {
            messages[lastIndex] = message
            return true
        }

        guard messages.count < maxMessages else {
            return false
        }
        messages.append(message)
        return true
    }

    public mutating func removeAll(keepingCapacity keepCapacity: Bool = false) {
        messages.removeAll(keepingCapacity: keepCapacity)
    }

    public mutating func drain() -> [VNCControlMessage] {
        let drained = messages
        messages.removeAll(keepingCapacity: true)
        return drained
    }
}

public extension VNCControlMessage {
    var isCoalesciblePointerMove: Bool {
        kind == "pointer" && x != nil && y != nil && button == nil && isDown == nil
    }
}
