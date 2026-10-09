import Foundation

/// One lane's messages waiting for the scheduler, oldest first.
struct LaneQueue {
    struct Message {
        let bytes: Data
        /// The last message of its frame.
        let endsFrame: Bool
    }

    let label: LaneLabel
    private(set) var messages: [Message] = []
    private var head = 0
    private(set) var queuedBytes = 0

    init(label: LaneLabel) {
        self.label = label
    }

    var isEmpty: Bool { head == messages.count }

    mutating func append(_ pieces: [Data]) {
        for (index, piece) in pieces.enumerated() {
            messages.append(Message(bytes: piece, endsFrame: index == pieces.count - 1))
            queuedBytes += piece.count
        }
    }

    mutating func popFirst() -> Message? {
        guard head < messages.count else { return nil }
        let message = messages[head]
        head += 1
        queuedBytes -= message.bytes.count
        if head == messages.count {
            messages.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 1024, head * 2 > messages.count {
            messages.removeFirst(head)
            head = 0
        }
        return message
    }
}
