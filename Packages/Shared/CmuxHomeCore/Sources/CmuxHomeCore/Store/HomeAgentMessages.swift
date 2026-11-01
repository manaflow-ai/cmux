import Foundation

/// Run steps stay after live replies settle. Projection happens only when the transcript changes.
struct HomeAgentMessages {
    private var runs: [String: HomeAgentRun] = [:]
    private(set) var liveVersion: UInt64 = 0
    private var liveRunVersions: [String: UInt64] = [:]
    private var liveStepVersions: [String: [String: UInt64]] = [:]

    mutating func apply(_ update: HomeAgentRun, preservingLiveAfter snapshot: UInt64? = nil) -> Bool {
        let key = "\(update.author.rawValue)\u{0}\(update.id)"
        let held = runs[key]
        if snapshot == nil {
            liveVersion += 1
            liveRunVersions[key] = liveVersion
            for message in update.messages { liveStepVersions[key, default: [:]][message.id] = liveVersion }
        }
        // Run metadata and individual steps have separate revision clocks. An older snapshot
        // can fill a missing step, but cannot move an already observed run to an older anchor.
        let preserveRun = snapshot.map { liveRunVersions[key, default: 0] > $0 } ?? false
        var next = held.map { update.revision > $0.revision || ($0.revision == 0 && !preserveRun) ? update : $0 } ?? update
        var messages = Dictionary((held?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for message in update.messages {
            // Snapshot responses can arrive after live changes to the same no-clock Cloud
            // step. Preserve only those touched since this read began; other steps can fill
            // from this snapshot, and a later refresh may replace them again.
            if let snapshot, let old = messages[message.id],
               (liveStepVersions[key]?[message.id] ?? 0) > snapshot,
               message.revision <= old.revision { continue }
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
    ///
    /// Two or more messages one Chief sent or got after the same row fold into one row that names
    /// their agents (``HomeAgentMessageRow/Kind/fold(count:peers:expanded:)``); a group in `expanded`
    /// keeps that row first and shows every message after it. A lone message shows as itself.
    func inserting(into items: [TranscriptItem], summary: ConversationSummary?,
                   expanded: Set<String> = []) -> [TranscriptItem] {
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
            // A nested question is the parent, not merely the thread's root. If only
            // Chief's reply is loaded, inherit its parent rather than replying to Chief.
            let parent = run.threadRoot.map { root in
                answer.flatMap { items[$0].messageID }.map { PartRef(message: $0, partIndex: 0) }
                    ?? items[anchor].replyTo ?? PartRef(message: root, partIndex: 0)
            }
            let chief = summary?.participants.first { $0.id == run.author }?.displayName ?? run.author.rawValue
            for message in run.messages {
                let from = message.outgoing ? chief : message.peer
                let to = message.outgoing ? message.peer : chief
                var item = TranscriptItem(
                    key: IdempotencyKey("agent-message:\(run.author.rawValue):\(run.id):\(message.id)"), seq: nil,
                    author: run.author, parts: [.text("[\(from) → \(to)]\n\(message.text)")], createdAt: message.date,
                    delivery: .committed, replyTo: parent, threadRoot: run.threadRoot)
                item.isReadOnly = true
                item.agentMessage = HomeAgentMessageRow(
                    group: HomeAgentMessageRow.groupID(author: run.author, anchor: items[anchor].key),
                    kind: Self.kind(from: from, to: to, message))
                after[anchor, default: []].append(item)
            }
        }
        return items.enumerated().flatMap { index, item in
            // Stable sorting keeps the run's numeric step sequence when fragments
            // share a timestamp; their opaque IDs are not a chronological key.
            let messages = (after[index] ?? []).sorted { $0.createdAt < $1.createdAt }
            return [item] + Self.folded(messages, expanded: expanded)
        }
    }

    /// A report that is only a status note (the agent stopped with no report) is a note; every other step a message.
    private static func kind(from: String, to: String, _ message: HomeAgentRun.Message) -> HomeAgentMessageRow.Kind {
        if !message.outgoing, let reason = HomeAgentMessageRow.statusNote(message.text) {
            let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast()
            return .note(peer: from, reason: reason, text: String(words))
        }
        return .message(from: from, to: to, outgoing: message.outgoing, text: message.text)
    }

    /// `messages` (one row's, in order) with each Chief's two or more messages behind one fold row,
    /// and its status notes, any number, behind one notes row after them (user 2026-10-31: five
    /// "stopped without a report" bubbles after one answer are one quiet line).
    private static func folded(_ messages: [TranscriptItem], expanded: Set<String>) -> [TranscriptItem] {
        guard !messages.isEmpty else { return messages }
        var groups: [String] = []
        var byGroup: [String: [TranscriptItem]] = [:]
        for message in messages {
            guard let group = message.agentMessage?.group else { continue }
            if byGroup[group] == nil { groups.append(group) }
            byGroup[group, default: []].append(message)
        }
        return groups.flatMap { group -> [TranscriptItem] in
            var notes: [TranscriptItem] = [], others: [TranscriptItem] = []
            for member in byGroup[group] ?? [] {
                if case .note? = member.agentMessage?.kind { notes.append(member) } else { others.append(member) }
            }
            return fold(others, group: group, expanded: expanded) + foldNotes(notes, group: group, expanded: expanded)
        }
    }

    /// Two or more messages behind one fold row; one message shows as itself.
    private static func fold(_ members: [TranscriptItem], group: String, expanded: Set<String>) -> [TranscriptItem] {
        guard members.count > 1, let first = members.first else { return members }
        var peers: [String] = [], seenPeers: Set<String> = []
        for member in members {
            guard case let .message(from, to, outgoing, _)? = member.agentMessage?.kind else { continue }
            let peer = outgoing ? to : from
            if seenPeers.insert(peer).inserted { peers.append(peer) }
        }
        let open = expanded.contains(group)
        var fold = TranscriptItem(
            key: IdempotencyKey("agent-messages:\(group)"), seq: nil, author: first.author,
            parts: [.text("\(open ? "▾" : "▸") \(HomeAgentMessageRow.peerPreview(peers, separator: " · "))")], createdAt: first.createdAt,
            delivery: .committed, replyTo: first.replyTo, threadRoot: first.threadRoot)
        fold.isReadOnly = true
        fold.agentMessage = HomeAgentMessageRow(group: group, kind: .fold(count: members.count, peers: peers, expanded: open))
        return open ? [fold] + members : [fold]
    }

    /// Status notes behind one notes row, whose group is ``HomeAgentMessageRow/notesGroup(_:)``.
    private static func foldNotes(_ notes: [TranscriptItem], group: String, expanded: Set<String>) -> [TranscriptItem] {
        guard let first = notes.first else { return [] }
        var peers: [String] = [], seenPeers: Set<String> = [], reasons: [HomeAgentMessageRow.StatusNote] = []
        for note in notes {
            guard case let .note(peer, reason, _)? = note.agentMessage?.kind else { continue }
            if seenPeers.insert(peer).inserted { peers.append(peer) }
            if !reasons.contains(reason) { reasons.append(reason) }
        }
        let notesGroup = HomeAgentMessageRow.notesGroup(group)
        let open = expanded.contains(notesGroup)
        var row = TranscriptItem(
            key: IdempotencyKey("agent-notes:\(group)"), seq: nil, author: first.author,
            parts: [.text("\(open ? "▾" : "▸") \(HomeAgentMessageRow.peerPreview(peers, separator: " · "))")], createdAt: first.createdAt,
            delivery: .committed, replyTo: first.replyTo, threadRoot: first.threadRoot)
        row.isReadOnly = true
        row.agentMessage = HomeAgentMessageRow(group: notesGroup, kind: .notes(
            count: notes.count, peers: peers, reason: reasons.count == 1 ? reasons.first : nil, expanded: open))
        return open ? [row] + notes : [row]
    }
}
