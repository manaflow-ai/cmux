import Foundation

// WireHomeSource's socket frames: the inbox stream and the open conversations'
// streams, turned into Home events (the daemon's `contract.rs` mapping:
// `conversation_change`, `inbox_entries`, `snapshot_parts`).
extension WireHomeSource {
    func handle(_ event: HomeWireStreamEvent, from target: HomeWireStreamTarget, stream: HomeWireStream) async {
        guard !stopped else { return }
        switch target {
        case .inbox: await handleInbox(event)
        case .conversation(let id): await handleConversation(event, id, stream: stream)
        }
    }

    // MARK: Inbox stream

    private func handleInbox(_ event: HomeWireStreamEvent) async {
        switch event {
        case .welcome(let user, let resumed):
            learn(user)
            // A fresh subscribe gets a snapshot, which reloads the inbox; a
            // resume replays only what was missed, so read the inbox now.
            if resumed { _ = try? await loadInbox() }
        case .snapshot:
            _ = try? await loadInbox()
        case .event(let frame):
            applyInbox(frame)
        case .typing:
            break
        case .disconnected, .refused:
            setConnection(.offline(since: Date()))
        }
    }

    /// The principal the server names (`user_…`, or a bare id the hosted
    /// owner prefixes) is who this source acts as.
    private func learn(_ user: String?) {
        guard let user, !user.isEmpty else { return }
        let id = ParticipantID(user.hasPrefix("user_") ? user : "user_\(user)")
        guard me?.id != id else { return }
        let name = heads.values.lazy.flatMap(\.participants).first { $0.id == id }?.displayName
        me = Participant(id: id, kind: .human, displayName: name ?? me?.displayName ?? displayName)
    }

    /// The entries an inbox event wrote (upserts of table `entry`).
    private func applyInbox(_ frame: HomeWireJSON) {
        guard me != nil, let writes = frame["effects"]["writes"].array else {
            // Nothing this build can read: start again from the list.
            // task-owner: one inbox read; ends with its reply
            Task { _ = try? await loadInbox() }
            return
        }
        var stale: [ConversationID] = []
        for write in writes where write["table"].string == "entry" && write["op"].string == "upsert" {
            let entry = write["row"]
            guard let raw = entry["conversation"].string else { continue }
            let id = ConversationID(raw)
            if mapping.isListed(entry) {
                entries[id] = entry
                created.remove(id)
                guard let summary = joined(id) else { continue }
                inboxRev += 1
                publish(.conversationChanged(summary, stream: .inbox, rev: inboxRev))
                // A new message in a conversation not on screen: its preview comes from a head read.
                if heads[id] == nil || (heads[id]?.lastSeq ?? 0) < (entry["last_seq"].uint ?? 0) { stale.append(id) }
            } else if entries.removeValue(forKey: id) != nil || created.remove(id) != nil {
                if conversationStreams[id] == nil { heads[id] = nil }
                inboxRev += 1
                publish(.conversationRemoved(id, inboxRev: inboxRev))
            }
        }
        hydrate(stale)
    }

    // MARK: Conversation streams

    private func handleConversation(_ event: HomeWireStreamEvent, _ id: ConversationID, stream: HomeWireStream) async {
        // A stream closed meanwhile (or replaced) reports nothing more.
        guard conversationStreams[id] === stream else { return }
        switch event {
        case .welcome:
            break
        case .snapshot(let frame):
            guard var page = mapping.page(frame) else {
                await stream.resync()
                return
            }
            heads[id] = page.conversation
            page.conversation = joined(id) ?? page.conversation
            publish(.conversationPage(page))
        case .event(let frame):
            guard apply(frame, in: id) else {
                await stream.resync()
                return
            }
        case .typing(let frame):
            guard frame["conversation"].string == id.rawValue, let who = frame["participant"].string, !who.isEmpty,
                  let on = frame["on"].bool else { return }
            let participant = ParticipantID(who)
            guard participant != me?.id else { return }
            if on { typists[id, default: []].insert(participant) } else { typists[id]?.remove(participant) }
            publish(.typing(id, participant, on: on))
        case .disconnected:
            // No typing-off can come on a socket that ended.
            endTyping(in: id)
        case .refused:
            endTyping(in: id)
            conversationStreams[id] = nil
        }
    }

    /// One conversation event: its message upsert as `.message`, any other
    /// change (cursor, title, members, settings) as `.conversationChanged`,
    /// at the head's revision. False when the frame carries no head (the
    /// stream then resyncs from a snapshot).
    private func apply(_ frame: HomeWireJSON, in id: ConversationID) -> Bool {
        guard !(frame["op"].string ?? "").hasPrefix("conversation.import") else { return false }
        let effects = frame["effects"]
        let head = effects["state"]
        guard head.object != nil, let rev = head["rev"].uint,
              var summary = mapping.summary(head, lastMessage: heads[id]?.lastMessage) else { return false }
        let messages = (effects["writes"].array ?? [])
            .filter { $0["table"].string == "msg" && $0["op"].string == "upsert" }
            .compactMap { mapping.message($0["row"]) }
        if let message = messages.last {
            if let last = summary.lastMessage, last.seq > message.seq {
                // An edit or a reaction of an older message: the preview stays.
            } else {
                summary.lastMessage = message
            }
            heads[id] = summary
            publish(.message(message, rev: rev))
        } else {
            heads[id] = summary
            publish(.conversationChanged(joined(id) ?? summary, stream: .conversation(id), rev: rev))
        }
        return true
    }

    func endTyping(in conversation: ConversationID) {
        guard let who = typists.removeValue(forKey: conversation) else { return }
        for participant in who.sorted(by: { $0.rawValue < $1.rawValue }) {
            publish(.typing(conversation, participant, on: false))
        }
    }
}
