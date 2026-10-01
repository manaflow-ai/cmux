/// Folds ``ConversationEnvelope``s and local sends into ``ConversationState``.
///
/// Events may arrive twice (a history page racing a live event) or out of
/// order (an older page loaded after newer ones). The reducer keeps the
/// loaded events ordered by cursor: anything already seen is dropped, a new
/// newest event is applied in place, and anything older triggers a refold of
/// the loaded history, so a page that starts in the middle of a turn ends up
/// exactly as if it had arrived in order.
///
/// Rows have stable identities: a user message is `user:<clientMessageID>`
/// from the moment this device shows it until the agent receives it, so the
/// backend's echo updates the row in place.
public struct ConversationReducer: Sendable {
    /// Creates a reducer.
    public init() {}

    /// Applies events from a history page or the live stream.
    /// - Parameters:
    ///   - envelopes: Events in any order; duplicates are ignored.
    ///   - state: The state to update.
    public func apply(_ envelopes: [ConversationEnvelope], to state: inout ConversationState) {
        let known = Set(state.log.map(\.cursor.order))
        var fresh: [ConversationEnvelope] = []
        var seen = Set<UInt64>()
        for e in envelopes where !known.contains(e.cursor.order) && seen.insert(e.cursor.order).inserted {
            fresh.append(e)
        }
        guard !fresh.isEmpty else { return }
        fresh.sort { $0.cursor < $1.cursor }
        if let newest = state.log.last?.cursor, fresh[0].cursor < newest {
            state.log.append(contentsOf: fresh)
            state.log.sort { $0.cursor < $1.cursor }
            refold(&state)
        } else {
            state.log.append(contentsOf: fresh)
            for e in fresh {
                fold(e, into: &state)
            }
            appendUnconfirmedLocalSends(&state)
        }
    }

    /// Records whether older history exists beyond what is loaded.
    /// - Parameters:
    ///   - hasOlder: Older events exist on the backend.
    ///   - state: The state to update.
    public func setHasOlder(_ hasOlder: Bool, in state: inout ConversationState) {
        state.hasOlder = hasOlder
    }

    /// Applies the latest title, status, mode and model.
    /// - Parameters:
    ///   - metadata: The facts; `nil` fields are left as they are.
    ///   - state: The state to update.
    public func applyMetadata(_ metadata: ConversationMetadata, to state: inout ConversationState) {
        if let t = metadata.title { state.title = t }
        if let s = metadata.status, state.status != .deleted { state.status = s }
        if let m = metadata.mode { state.mode = m }
        if let m = metadata.model { state.model = m }
    }

    /// Shows a message the user just sent, before the backend confirms it.
    /// - Parameters:
    ///   - message: The outgoing message.
    ///   - state: The state to update.
    public func applyLocalSend(_ message: OutgoingMessage, to state: inout ConversationState) {
        let id = message.clientMessageID
        if state.localSends[id] == nil {
            state.localOrder.append(id)
        }
        state.localSends[id] = .init(message: message, failed: false)
        for a in message.attachments where state.attachments[a.uploadID] == nil {
            state.attachments[a.uploadID] = a.asConversationAttachment
        }
        if !state.items.contains(where: { $0.id == Self.userID(id) }) {
            state.items.append(localItem(state.localSends[id]!))
        }
    }

    /// Marks a local message as not delivered (the backend is unreachable),
    /// or as sending again.
    /// - Parameters:
    ///   - id: The message's client identifier.
    ///   - failed: Whether delivery failed.
    ///   - state: The state to update.
    public func setLocalSendFailed(_ id: ClientMessageID, failed: Bool, in state: inout ConversationState) {
        guard state.localSends[id] != nil else { return }
        state.localSends[id]?.failed = failed
        if let i = state.items.firstIndex(where: { $0.id == Self.userID(id) }), case var .message(m) = state.items[i].kind, m.delivery == .sending || m.delivery == .failed {
            m.delivery = failed ? .failed : .sending
            state.items[i].kind = .message(m)
        }
    }

    /// Reports how many bytes of a local file this device has sent.
    /// - Parameters:
    ///   - uploadID: The file's upload identifier.
    ///   - sent: Bytes sent so far.
    ///   - state: The state to update.
    public func applyLocalUploadProgress(uploadID: String, sent: UInt64, to state: inout ConversationState) {
        guard var a = state.attachments[uploadID] else { return }
        switch a.state {
        case let .uploading(received) where sent > received:
            a.state = .uploading(received: sent)
        case .failed:
            a.state = .uploading(received: sent)
        default:
            return
        }
        state.attachments[uploadID] = a
    }

    /// Marks a local file as missing (the original is gone from this device).
    /// - Parameters:
    ///   - uploadID: The file's upload identifier.
    ///   - state: The state to update.
    public func markLocalAttachmentMissing(uploadID: String, in state: inout ConversationState) {
        state.attachments[uploadID]?.state = .missing
    }

    /// Messages sent from this device that the backend has not confirmed, in order.
    /// - Parameter state: The state to read.
    /// - Returns: The unconfirmed messages.
    public func unconfirmedSends(in state: ConversationState) -> [OutgoingMessage] {
        state.localOrder.compactMap { state.localSends[$0]?.message }
    }

    // MARK: - Folding

    static func userID(_ id: ClientMessageID) -> String { "user:\(id.rawValue)" }

    private func refold(_ state: inout ConversationState) {
        var fresh = ConversationState()
        fresh.log = state.log
        fresh.hasOlder = state.hasOlder
        fresh.localSends = state.localSends
        fresh.localOrder = state.localOrder
        for (id, a) in state.attachments where a.state != .uploaded {
            // Local upload progress is not in the log; keep it.
            fresh.attachments[id] = a
        }
        for e in fresh.log {
            fold(e, into: &fresh)
        }
        appendUnconfirmedLocalSends(&fresh)
        state = fresh
    }

    private func appendUnconfirmedLocalSends(_ state: inout ConversationState) {
        for id in state.localOrder {
            guard let send = state.localSends[id] else { continue }
            if !state.items.contains(where: { $0.id == Self.userID(id) }) {
                state.items.append(localItem(send))
            }
        }
    }

    private func localItem(_ send: ConversationState.LocalSend) -> ConversationItem {
        let m = send.message
        return ConversationItem(
            id: Self.userID(m.clientMessageID),
            kind: .message(ConversationMessage(role: .user, text: m.text, attachmentIDs: m.attachments.map(\.uploadID), clientMessageID: m.clientMessageID, delivery: send.failed ? .failed : .sending))
        )
    }

    private func confirm(_ id: ClientMessageID?, in state: inout ConversationState) {
        guard let id, state.localSends.removeValue(forKey: id) != nil else { return }
        state.localOrder.removeAll { $0 == id }
    }

    /// Puts a user message row at the end, keeping its identity.
    private func placeUserMessage(id: ClientMessageID?, order: UInt64, timestamp: UInt64?, text: String, attachments: [ConversationAttachment], delivery: DeliveryState, in state: inout ConversationState) {
        for a in attachments {
            state.attachments[a.uploadID] = merged(a, into: state.attachments[a.uploadID])
        }
        let rowID = id.map(Self.userID) ?? "user:o\(order)"
        state.items.removeAll { $0.id == rowID }
        let message = ConversationMessage(role: .user, text: text, attachmentIDs: attachments.map(\.uploadID), clientMessageID: id, delivery: delivery)
        state.items.append(ConversationItem(id: rowID, kind: .message(message), timestamp: timestamp))
        confirm(id, in: &state)
    }

    /// A declaration in a message never moves a file backwards in state.
    private func merged(_ incoming: ConversationAttachment, into existing: ConversationAttachment?) -> ConversationAttachment {
        guard var existing else { return incoming }
        existing.name = incoming.name
        existing.mimeType = incoming.mimeType
        existing.size = incoming.size
        existing.sha256 = incoming.sha256
        existing.thumbnailUploadID = existing.thumbnailUploadID ?? incoming.thumbnailUploadID
        return existing
    }

    private func appendStreamed(_ text: String, reasoning: Bool, order: UInt64, timestamp: UInt64?, in state: inout ConversationState) {
        if let last = state.items.indices.last {
            switch state.items[last].kind {
            case var .message(m) where !reasoning && m.role == .assistant:
                m.text += text
                state.items[last].kind = .message(m)
                return
            case let .reasoning(t) where reasoning:
                state.items[last].kind = .reasoning(t + text)
                return
            default:
                break
            }
        }
        let kind: ConversationItem.Kind = reasoning ? .reasoning(text) : .message(ConversationMessage(role: .assistant, text: text))
        state.items.append(ConversationItem(id: (reasoning ? "reasoning:" : "assistant:") + String(order), kind: kind, timestamp: timestamp))
    }

    private func indexOfLastUser(_ state: ConversationState) -> Int? {
        state.items.lastIndex { item in
            if case let .message(m) = item.kind { return m.role == .user && m.delivery != .sending }
            return false
        }
    }

    func fold(_ e: ConversationEnvelope, into state: inout ConversationState) {
        let order = e.cursor.order
        let ts = e.timestamp
        switch e.event {
        case let .userMessage(id, text, attachments, steer):
            placeUserMessage(id: id, order: order, timestamp: ts, text: text, attachments: attachments, delivery: steer ? .steered : .delivered, in: &state)
        case let .userMessageQueued(id, text, attachments, position, held):
            placeUserMessage(id: id, order: order, timestamp: ts, text: text, attachments: attachments, delivery: held ? .uploading : .queued(position: position), in: &state)
        case let .queueChanged(entries):
            state.queue = entries
            let positions = Dictionary(entries.compactMap { e in e.clientMessageID.map { ($0, e.position) } }, uniquingKeysWith: { a, _ in a })
            for i in state.items.indices {
                if case var .message(m) = state.items[i].kind, let id = m.clientMessageID, case .queued = m.delivery, let p = positions[id] {
                    m.delivery = .queued(position: p)
                    state.items[i].kind = .message(m)
                }
            }
        case let .userMessageDequeued(id, text):
            if let id {
                state.items.removeAll { $0.id == Self.userID(id) }
                confirm(id, in: &state)
            } else if let i = state.items.lastIndex(where: { item in
                if case let .message(m) = item.kind, m.role == .user, m.text == text, case .queued = m.delivery { return true }
                return false
            }) {
                state.items.remove(at: i)
            }
        case let .userMessageFailed(id, text, attachments, failed):
            placeUserMessage(id: id, order: order, timestamp: ts, text: text, attachments: attachments, delivery: .failed, in: &state)
            for f in failed {
                if state.attachments[f]?.state != .missing {
                    state.attachments[f]?.state = .failed
                }
            }
        case let .attachmentChanged(a):
            var updated = merged(a, into: state.attachments[a.uploadID])
            updated.state = a.state
            state.attachments[a.uploadID] = updated
        case let .attachmentProgress(uploadID, received):
            if case let .uploading(r)? = state.attachments[uploadID]?.state, received > r {
                state.attachments[uploadID]?.state = .uploading(received: received)
            }
        case let .assistantText(t):
            appendStreamed(t, reasoning: false, order: order, timestamp: ts, in: &state)
        case let .reasoningText(t):
            appendStreamed(t, reasoning: true, order: order, timestamp: ts, in: &state)
        case let .activityStarted(id, activity):
            let rowID = "activity:\(id)"
            if let i = state.items.firstIndex(where: { $0.id == rowID }) {
                state.items[i].kind = .activity(activity)
            } else {
                state.items.append(ConversationItem(id: rowID, kind: .activity(activity), timestamp: ts))
            }
        case let .activityUpdated(id, status, title, detail):
            let rowID = "activity:\(id)"
            if let i = state.items.firstIndex(where: { $0.id == rowID }), case var .activity(a) = state.items[i].kind {
                if let status { a.status = status }
                if let title { a.title = title }
                if let detail { a.detail = detail }
                state.items[i].kind = .activity(a)
            } else {
                // An update whose start is on an older, unloaded page.
                let a = ActivityItem(kind: "other", title: title ?? "", status: status ?? "in_progress", detail: detail ?? "")
                state.items.append(ConversationItem(id: rowID, kind: .activity(a), timestamp: ts))
            }
        case let .plan(entries):
            let start = (indexOfLastUser(state) ?? -1) + 1
            let isPlan: (ConversationItem) -> Bool = { item in
                if case .plan = item.kind { return true }
                return false
            }
            if let i = state.items.indices.last(where: { $0 >= start && isPlan(state.items[$0]) }) {
                state.items[i].kind = .plan(entries)
            } else {
                state.items.append(ConversationItem(id: "plan:\(order)", kind: .plan(entries), timestamp: ts))
            }
        case let .approvalRequested(r):
            let rowID = "approval:\(r.id)"
            if !state.items.contains(where: { $0.id == rowID }) {
                state.items.append(ConversationItem(id: rowID, kind: .approval(r), timestamp: ts))
            }
        case let .approvalResolved(id, option):
            if let i = state.items.firstIndex(where: { $0.id == "approval:\(id)" }), case var .approval(r) = state.items[i].kind {
                r.decision = option ?? "cancelled"
                state.items[i].kind = .approval(r)
            }
        case .turnStarted:
            state.status = .running
        case let .turnEnded(stop, error):
            if let error {
                state.items.append(ConversationItem(id: "error:\(order)", kind: .error(error), timestamp: ts))
            }
            state.items.append(ConversationItem(id: "turn:\(order)", kind: .turnEnded(stopReason: stop), timestamp: ts))
        case let .statusChanged(s):
            if state.status != .deleted { state.status = s }
        case let .titleChanged(t):
            state.title = t
        case let .modeChanged(m):
            state.mode = m
        case let .modelChanged(m):
            state.model = m
        case let .usage(used, size):
            state.usage = .init(used: used, size: size)
        case let .notice(t):
            state.items.append(ConversationItem(id: "notice:\(order)", kind: .notice(t), timestamp: ts))
        case let .error(t):
            state.items.append(ConversationItem(id: "error:\(order)", kind: .error(t), timestamp: ts))
        case .deleted:
            state.status = .deleted
        case let .extension(x):
            state.items.append(ConversationItem(id: "ext:\(order)", kind: .extension(x), timestamp: ts))
        }
    }
}
