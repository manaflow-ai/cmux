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
    /// keeps that row first and shows every message after it. `seen` is each agent's newest report time the
    /// person opened (``HomeStore/markAgentSeen(_:in:)``): a pill whose report is newer shows the unread dot.
    func inserting(into items: [TranscriptItem], summary: ConversationSummary?,
                   expanded: Set<String> = [], seen: [String: Date] = [:]) -> [TranscriptItem] {
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
        let titles = taskTitles()
        return items.enumerated().flatMap { index, item in
            // Stable sorting keeps the run's numeric step sequence when fragments
            // share a timestamp; their opaque IDs are not a chronological key.
            let messages = (after[index] ?? []).sorted { $0.createdAt < $1.createdAt }
            return [item] + Self.folded(messages, expanded: expanded, seen: seen, titles: titles)
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

    /// `messages` (one row's, in order) behind one agents row per Chief: one pill per agent the Chief
    /// told or heard from after that row (user 2026-11-03, msg 19960), status notes included (they stop
    /// the agent's pill), so a lone task is a pill too and five "stopped without a report" notes are no
    /// second row.
    private static func folded(_ messages: [TranscriptItem], expanded: Set<String>, seen: [String: Date],
                               titles: [String: String]) -> [TranscriptItem] {
        guard !messages.isEmpty else { return messages }
        var groups: [String] = []
        var byGroup: [String: [TranscriptItem]] = [:]
        for message in messages {
            guard let group = message.agentMessage?.group else { continue }
            if byGroup[group] == nil { groups.append(group) }
            byGroup[group, default: []].append(message)
        }
        return groups.flatMap { fold(byGroup[$0] ?? [], group: $0, expanded: expanded, seen: seen, titles: titles) }
    }

    /// One agents row for `members`, then every member in order when the group is open.
    ///
    /// Each agent, first-seen order: its state is its newest member's (the Chief's message: told; a
    /// report: reported; a status note: stopped); its title is its task's `Title:` line in any run
    /// (`titles`, ``taskTitles()``), else the Chief's first message to it in this row.
    private static func fold(_ members: [TranscriptItem], group: String, expanded: Set<String>,
                             seen: [String: Date], titles known: [String: String]) -> [TranscriptItem] {
        guard let first = members.first else { return [] }
        var peers: [String] = [], seenPeers: Set<String> = []
        var states: [String: HomeAgentMessageRow.PeerState] = [:], latest: String?, titles: [String: String] = [:]
        var reportedAt: [String: Date] = [:]
        for member in members {
            let peer: String
            switch member.agentMessage?.kind {
            case let .message(from, to, outgoing, text)?:
                peer = outgoing ? to : from
                states[peer] = outgoing ? .told : .reported
                if outgoing, titles[peer] == nil { titles[peer] = HomeAgentMessageRow.title(of: text) }
                if !outgoing { reportedAt[peer] = member.createdAt }
                latest = text
            case let .note(notePeer, _, text)?:
                peer = notePeer
                states[peer] = .stopped
                latest = text
            default:
                continue
            }
            if seenPeers.insert(peer).inserted { peers.append(peer) }
        }
        let open = expanded.contains(group)
        var fold = TranscriptItem(
            key: IdempotencyKey("agent-messages:\(group)"), seq: nil, author: first.author,
            parts: [.text("\(open ? "▾" : "▸") \(HomeAgentMessageRow.peerPreview(peers, separator: " · "))")], createdAt: first.createdAt,
            delivery: .committed, replyTo: first.replyTo, threadRoot: first.threadRoot)
        fold.isReadOnly = true
        fold.agentMessage = HomeAgentMessageRow(group: group, kind: .fold(count: members.count, peers: peers, expanded: open))
        fold.agentMessage?.peerStates = peers.map { states[$0] ?? .told }
        fold.agentMessage?.latest = latest
        fold.agentMessage?.peerTitles = peers.map { known[$0] ?? titles[$0] ?? $0 }
        fold.agentMessage?.peerUnread = peers.map { peer in
            guard states[peer] == .reported, let at = reportedAt[peer] else { return false }
            return seen[peer].map { $0 < at } ?? true
        }
        return open ? [fold] + members : [fold]
    }

    /// `peer`'s chat with the Chief over every run of the conversation (``HomeAgentThread``), or nil
    /// when no run has a message with it. `items` are the conversation's own rows: the Chief's link
    /// to the agent's session comes from its words there.
    func thread(peer: String, in items: [TranscriptItem], me: ParticipantID? = nil) -> HomeAgentThread? {
        let messages = runs.values.flatMap { run in run.messages.filter { $0.peer == peer } }
            .sorted { ($0.date, $0.sequence, $0.id) < ($1.date, $1.sequence, $1.id) }
        guard let first = messages.first, let last = messages.last else { return nil }
        let task = messages.first(where: \.outgoing)
        let title = taskTitles(peer: peer)[peer] ?? task.flatMap { HomeAgentMessageRow.title(of: $0.text) } ?? peer
        var entries = messages.filter { $0.id != task?.id }.map { message in
            HomeAgentThread.Entry(id: message.id, outgoing: message.outgoing, text: message.text, date: message.date,
                                  sender: message.outgoing ? message.sender.flatMap(HomeAgentSender.init(meta:)) ?? .chief : .agent)
        }
        if let me { Self.addNotes(to: &entries, peer: peer, from: items, me: me) }
        let state: HomeAgentMessageRow.PeerState = last.outgoing ? .told
            : HomeAgentMessageRow.statusNote(last.text) != nil ? .stopped : .reported
        let chief = items.lazy.filter { !$0.isReadOnly }.map(\.plainText)
        return HomeAgentThread(
            peer: peer, title: title, state: state, task: task?.text,
            entries: entries, startedAt: first.date, endedAt: state == .told ? nil : last.date,
            newestReportAt: messages.last(where: { !$0.outgoing })?.date,
            workspaceLink: HomeAgentThread.workspaceLink(for: peer, in: chief))
    }

    /// Each agent's name over every run: the `Title:` line of the earliest message to it that has one (its
    /// spawn task, `Title: <2-5 words>`), so a later tell ("User (Nov 4): …") never renames its pill or chat
    /// (user 2026-11-04, msg 21664). An agent with no such message is absent. `peer`: only that agent.
    private func taskTitles(peer: String? = nil) -> [String: String] {
        var titles: [String: (date: Date, title: String)] = [:]
        for run in runs.values {
            for message in run.messages where message.outgoing && (peer == nil || message.peer == peer) {
                guard titles[message.peer].map({ message.date < $0.date }) ?? true,
                      let title = Self.titleLine(of: message.text) else { continue }
                titles[message.peer] = (message.date, title)
            }
        }
        return titles.mapValues(\.title)
    }

    /// `text`'s `Title:` line's words; nil when it has none.
    private static func titleLine(of text: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix("title:") else { continue }
            let title = trimmed.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// The person's own ``HomeAgentNote``s to `peer` in `items`, labelled You: a Chief message that says the
    /// same words after it is its relay and shows once (as the person's); a note not relayed yet shows at once.
    private static func addNotes(to entries: inout [HomeAgentThread.Entry], peer: String, from items: [TranscriptItem],
                                 me: ParticipantID) {
        var added = false
        for item in items where item.author == me && !item.isReadOnly && !item.isRetracted
            && item.agentMessage == nil && item.feedRow == nil {
            guard let note = HomeAgentNote(parsing: item.plainText), note.peer == peer else { continue }
            let words = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The relay is written after the note; a clock on another machine may run a little behind.
            let earliest = item.createdAt.addingTimeInterval(-300)
            if let relay = entries.firstIndex(where: { $0.outgoing && $0.sender != .you && $0.date >= earliest
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == words }) {
                entries[relay].sender = .you
            } else {
                entries.append(HomeAgentThread.Entry(id: "note:\(item.key.rawValue)", outgoing: true, text: words,
                                                     date: item.createdAt, sender: .you))
                added = true
            }
        }
        // Stable: messages at the same time keep their order.
        if added {
            entries = entries.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
        }
    }
}
