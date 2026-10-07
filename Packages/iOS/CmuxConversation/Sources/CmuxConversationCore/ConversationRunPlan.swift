import Foundation

/// Messages grouping rules, independent of rendering: which messages start a
/// timestamp section, which bubbles form a run (tail on the last), and which
/// single outgoing message carries the delivery status.
public struct ConversationRunPlan: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        case none
        case delivered
        case read(Date?)
        case notDelivered
    }

    public struct Entry: Sendable, Equatable {
        public var showsTimestamp: Bool
        public var isFirstInRun: Bool
        public var isLastInRun: Bool
        public var status: Status
    }

    public var entries: [Entry]

    /// A gap this long starts a new timestamp section.
    public static let timestampGap: TimeInterval = 60 * 60
    /// Same-sender messages further apart than this start a new run.
    public static let runGap: TimeInterval = 5 * 60

    public init(messages: [ConversationMessage], meID: String?, typingParticipantIDs: [String] = []) {
        // Status sits under the newest delivered/read message of mine; it moves
        // only once a newer one is delivered, never while that one is in flight.
        var lastAckedOutgoing = messages.lastIndex { message in
            guard message.senderID == meID else { return false }
            switch message.delivery {
            case .delivered, .read: return true
            default: return false
            }
        }
        // Once someone replies below it, the status has done its job.
        if let index = lastAckedOutgoing, messages[(index + 1)...].contains(where: { $0.senderID != meID }) {
            lastAckedOutgoing = nil
        }
        var entries: [Entry] = []
        entries.reserveCapacity(messages.count)
        // Neighbors are read in place: copying whole messages into optionals
        // dominated this pass, which runs over every loaded message per update.
        for index in messages.indices {
            let message = messages[index]
            let hasPrevious = index > 0
            let hasNext = index + 1 < messages.count
            let showsTimestamp = hasPrevious ? message.sentAt.timeIntervalSince(messages[index - 1].sentAt) >= Self.timestampGap : true
            let firstInRun = showsTimestamp || !(hasPrevious && Self.sameRun(messages[index - 1], message))
            let lastInRun: Bool
            if !hasNext {
                lastInRun = !typingParticipantIDs.contains(message.senderID)
            } else if messages[index + 1].sentAt.timeIntervalSince(message.sentAt) >= Self.timestampGap {
                lastInRun = true
            } else {
                lastInRun = !Self.sameRun(message, messages[index + 1])
            }
            let status: Status
            if message.delivery?.isFailed == true {
                status = .notDelivered
            } else if message.senderID == meID, index == lastAckedOutgoing {
                switch message.delivery {
                case .delivered: status = .delivered
                case let .read(date): status = .read(date)
                default: status = .none
                }
            } else {
                status = .none
            }
            entries.append(Entry(showsTimestamp: showsTimestamp, isFirstInRun: firstInRun, isLastInRun: lastInRun, status: status))
        }
        self.entries = entries
    }

    static func sameRun(_ a: ConversationMessage, _ b: ConversationMessage) -> Bool {
        a.senderID == b.senderID && b.sentAt.timeIntervalSince(a.sentAt) < runGap && b.replyToID == nil
    }
}
