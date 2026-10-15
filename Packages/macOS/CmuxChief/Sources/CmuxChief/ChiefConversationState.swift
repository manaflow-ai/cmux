import CmuxHomeCore
import Foundation

/// One conversation as the owner holds it: its summary, every message in seq
/// order (seq `n` at index `n - 1`), and the brain's CLI session.
struct ChiefConversationState: Sendable {
    var summary: ConversationSummary
    private(set) var messages: [Message] = []
    private var indexByID: [MessageID: Int] = [:]
    var cliSession: String?

    init(summary: ConversationSummary, messages: [Message] = [], cliSession: String? = nil) {
        self.summary = summary
        self.cliSession = cliSession
        for message in messages.sorted(by: { $0.seq < $1.seq }) { upsert(message) }
    }

    var id: ConversationID { summary.id }

    func message(_ id: MessageID) -> Message? {
        indexByID[id].map { messages[$0] }
    }

    func message(clientID key: IdempotencyKey) -> Message? {
        messages.last { $0.clientMessageID == key }
    }

    /// The first Chief among the participants (the one that answers).
    var chief: Participant? { summary.participants.first(where: \.isChief) }

    /// Adds a new message or replaces a known one (by id). Loading uses it
    /// for every record; the owner uses it for commits and updates.
    mutating func upsert(_ message: Message) {
        if let index = indexByID[message.id] {
            messages[index] = message
        } else {
            indexByID[message.id] = messages.count
            messages.append(message)
        }
        if summary.lastMessage?.id == message.id || message.seq >= summary.lastSeq {
            summary.lastMessage = message
        }
        summary.lastSeq = max(summary.lastSeq, message.seq)
    }

    /// Replies whose thread root is `root`, ascending.
    func replies(to root: MessageID) -> [Message] {
        messages.filter { $0.threadRoot == root }
    }

    /// The owner's thread stats of the roots among `page`.
    func threadSummaries(in page: [Message]) -> [ThreadSummary] {
        let roots = Set(page.filter { $0.threadRoot == nil }.map(\.id))
        guard !roots.isEmpty else { return [] }
        var byRoot: [MessageID: [Message]] = [:]
        for message in messages {
            if let root = message.threadRoot, roots.contains(root) { byRoot[root, default: []].append(message) }
        }
        return byRoot.map { ThreadSummary(root: $0.key, replies: $0.value) }
    }

    /// Messages with `first <= seq <= last`.
    func messages(from first: Seq, through last: Seq) -> [Message] {
        guard first >= 1, first <= last, !messages.isEmpty else { return [] }
        let lower = Int(first) - 1
        let upper = min(Int(last), messages.count)
        guard lower < upper else { return [] }
        return Array(messages[lower..<upper])
    }
}
