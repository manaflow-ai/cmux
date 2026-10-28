import Foundation

/// Run steps stay after live replies settle. Projection happens only when the transcript changes.
struct HomeAgentMessages {
    private var runs: [String: HomeAgentRun] = [:]

    mutating func apply(_ update: HomeAgentRun) -> Bool {
        let key = "\(update.author.rawValue)\u{0}\(update.id)"
        var next = update
        if let held = runs[key] {
            var messages = Dictionary(uniqueKeysWithValues: held.messages.map { ($0.id, $0) })
            for message in update.messages where message.revision >= (messages[message.id]?.revision ?? 0) {
                messages[message.id] = message
            }
            next.messages = Array(messages.values)
        }
        next.messages.sort { ($0.sequence, $0.id) < ($1.sequence, $1.id) }
        guard runs[key] != next else { return false }
        runs[key] = next
        return true
    }

    /// Insert by the owner's reply/answer keys, never by sorting committed messages on a clock.
    func inserting(into items: [TranscriptItem], summary: ConversationSummary?) -> [TranscriptItem] {
        guard !runs.isEmpty else { return items }
        var byKey: [IdempotencyKey: Int] = [:]
        var byMessageID: [MessageID: Int] = [:]
        for (index, item) in items.enumerated() {
            byKey[item.key] = index
            if let messageID = item.messageID { byMessageID[messageID] = index }
        }
        var after: [Int: [TranscriptItem]] = [:]
        for run in runs.values.sorted(by: { ($0.author.rawValue, $0.id) < ($1.author.rawValue, $1.id) }) {
            let reply = run.turn.flatMap { byKey[$0] }.flatMap { index in
                items[index].author == run.author ? index : nil
            }
            let answer = run.answers.compactMap { byMessageID[$0] }.max()
            guard let anchor = reply ?? answer else { continue }
            let chief = summary?.participants.first { $0.id == run.author }?.displayName ?? run.author.rawValue
            for message in run.messages {
                let from = message.outgoing ? chief : message.peer
                let to = message.outgoing ? message.peer : chief
                var item = TranscriptItem(
                    key: IdempotencyKey("agent-message:\(run.author.rawValue):\(run.id):\(message.id)"), seq: nil,
                    author: run.author, parts: [.text("[\(from) → \(to)]\n\(message.text)")], createdAt: message.date,
                    delivery: .committed, threadRoot: run.threadRoot)
                item.isReadOnly = true
                after[anchor, default: []].append(item)
            }
        }
        return items.enumerated().flatMap { index, item in [item] + (after[index] ?? []) }
    }
}
