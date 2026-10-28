import Foundation

/// Run steps stay after live replies settle. Projection happens only when the transcript changes.
struct HomeAgentMessages {
    private var runs: [String: HomeAgentRun] = [:]

    mutating func apply(_ update: HomeAgentRun) -> Bool {
        let key = "\(update.author.rawValue)\u{0}\(update.id)"
        let held = runs[key]
        // Run metadata and individual steps have separate revision clocks. An older snapshot
        // can fill a missing step, but cannot move an already observed run to an older anchor.
        var next = held.map { update.revision > $0.revision || $0.revision == 0 ? update : $0 } ?? update
        var messages: [String: HomeAgentRun.Message] = [:]
        for message in (held?.messages ?? []) + update.messages {
            // Cloud has stable sequence numbers but no update revision. Its latest
            // received payload replaces the same step; sequence only orders rows.
            if let old = messages[message.id], old.revision > 0, old.revision >= message.revision { continue }
            messages[message.id] = message
        }
        next.messages = Array(messages.values)
        next.messages.sort { ($0.sequence, $0.id) < ($1.sequence, $1.id) }
        guard held != next else { return false }
        runs[key] = next
        // Talk/tool progress advances run revisions too. Only message content or placement
        // invalidates the transcript; a revision-only event must not walk every visible row.
        guard let held else { return !next.messages.isEmpty }
        guard !next.messages.isEmpty else { return false }
        return held.turn != next.turn || held.answers != next.answers || held.threadRoot != next.threadRoot
            || held.messages.count != next.messages.count
            || !zip(held.messages, next.messages).allSatisfy { old, new in
                old.id == new.id && old.sequence == new.sequence && old.peer == new.peer
                    && old.outgoing == new.outgoing && old.text == new.text && old.date == new.date
            }
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
            guard let anchor = answer ?? reply else { continue }
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
        return items.enumerated().flatMap { index, item in
            let messages = (after[index] ?? []).sorted {
                ($0.createdAt, $0.key.rawValue) < ($1.createdAt, $1.key.rawValue)
            }
            return [item] + messages
        }
    }
}
