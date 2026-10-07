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
        /// "Delivered Quietly": the recipient's Focus silenced notifications.
        case deliveredQuietly
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
            guard message.senderID == meID, !message.isUnsent, !message.isSystemEvent else { return false }
            switch message.delivery {
            case .delivered, .read: return true
            default: return false
            }
        }
        // Once someone replies below it, the status has done its job (a
        // status row such as someone leaving is not a reply).
        if let index = lastAckedOutgoing, messages[(index + 1)...].contains(where: { $0.senderID != meID && !$0.isSystemEvent }) {
            lastAckedOutgoing = nil
        }
        var entries: [Entry] = []
        entries.reserveCapacity(messages.count)
        // Send Later messages trail the transcript, each its own tailed bubble
        // under a "Send Later" header the renderer draws; the history above
        // groups as if they were not there.
        let firstScheduled = messages.firstIndex(where: \.isScheduled) ?? messages.count
        for (index, message) in messages.enumerated() {
            if index >= firstScheduled {
                let failed = message.delivery?.isFailed == true
                entries.append(Entry(showsTimestamp: false, isFirstInRun: true, isLastInRun: true, status: failed ? .notDelivered : .none))
                continue
            }
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < firstScheduled ? messages[index + 1] : nil
            let showsTimestamp = previous.map { message.sentAt.timeIntervalSince($0.sentAt) >= Self.timestampGap } ?? true
            let firstInRun = showsTimestamp || !(previous.map { Self.sameRun($0, message) } ?? false)
            let lastInRun: Bool = {
                guard let next else { return !typingParticipantIDs.contains(message.senderID) }
                if next.sentAt.timeIntervalSince(message.sentAt) >= Self.timestampGap { return true }
                return !Self.sameRun(message, next)
            }()
            let status: Status
            if message.delivery?.isFailed == true {
                status = .notDelivered
            } else if message.senderID == meID, index == lastAckedOutgoing {
                switch message.delivery {
                case .delivered: status = message.deliveredQuietly ? .deliveredQuietly : .delivered
                case let .read(date): status = .read(date)
                default: status = .none
                }
            } else {
                status = .none
            }
            // A status row under a bubble ends its visual run (Messages keeps
            // the tail there until the status moves to a newer message).
            entries.append(Entry(showsTimestamp: showsTimestamp, isFirstInRun: firstInRun, isLastInRun: lastInRun || status != .none, status: status))
        }
        self.entries = entries
    }

    static func sameRun(_ a: ConversationMessage, _ b: ConversationMessage) -> Bool {
        // An unsent message or a group status row renders as a centered
        // notice, which ends the run above it (that bubble regains its tail)
        // and starts a new one below (sender name and all).
        !a.isUnsent && !b.isUnsent && !a.isSystemEvent && !b.isSystemEvent && a.senderID == b.senderID && b.sentAt.timeIntervalSince(a.sentAt) < runGap && b.replyToID == nil
    }
}
