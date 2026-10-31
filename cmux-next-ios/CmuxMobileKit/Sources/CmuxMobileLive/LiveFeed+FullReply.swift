import CmuxMobileAgentChat
import CmuxMobileFeed
import Foundation
import OSLog

private let log = Logger(subsystem: "dev.cmux.mobile", category: "feed")

/// A finished turn's card shows the agent's whole reply, as its chat does.
///
/// A session summary carries only `preview`: the first 160 characters of the
/// last reply with its line breaks flattened (acpmux `chats/activity.rs`). A
/// Feed card built from it lost every list, code block and paragraph past the
/// first line. A Chief subagent's report reads whole because it arrives as a
/// message of its own; every other agent's turn read as one cut line. So each
/// turn card reads the session's transcript once, through the turn's
/// `turn_result`, and shows the turn's last agent message in full.
extension LiveFeed {
    /// The most transcript records read for one turn.
    static let replyPage = 400
    /// The most bytes of one read; with it the daemon also leaves out tool output a later update replaced.
    static let replyBytes = 1 << 20
    /// The most characters a card keeps of a reply (the chat has the rest).
    static let replyLimit = 16_000

    /// Reads the whole reply of `item` (turn `turnID` of `sessionID`, whose record `through`
    /// is at or after its `turn_result`) and puts it on the card.
    func readFullReply(of item: FeedItem, sessionID: String, turnID: String?, through seq: Int) {
        guard item.kind == .response, fullReplies[item.id] == nil, replyReads[item.id] == nil, let hub else { return }
        // task-owner: LiveFeed.replyReads: one transcript read per turn card; it ends with its request.
        replyReads[item.id] = Task { [weak self] in
            let page = try? await hub.request("_acpmux/events", .object([
                "sessionId": .string(sessionID),
                "beforeSeq": .number(Double(seq + 1)),
                "limit": .number(Double(Self.replyPage)),
                "maxBytes": .number(Double(Self.replyBytes)),
                "kinds": .array([.string("transcript")]),
            ]), timeout: .seconds(20))
            guard let self else { return }
            replyReads[item.id] = nil
            // A failed read is tried again on the next read of the Mac; an answer is kept, even "none".
            guard let page else { return }
            let complete = page["hasMore"].map { $0 == .bool(false) } ?? false
            let reply = Self.lastReply(page["events"]?.arrayValue ?? [], sessionID: sessionID, turnID: turnID, complete: complete)
            fullReplies[item.id] = reply ?? ""
            guard let reply, var current = store.item(id: item.id), current.kind == .response, current.markdown != reply else { return }
            log.info("feed reply \(item.id, privacy: .public): \(reply.count, privacy: .public) chars")
            current.markdown = reply
            store.upsert(current, atTop: false)
        }
    }

    /// The last agent message of turn `turnID` in `records` (a transcript page, any order, read
    /// through that turn's `turn_result`): its chunks joined. Nil when the page holds no reply, no
    /// `turn_result` of that turn, or only the end of the message: its start is known only after a
    /// prompt, a tool call, a thought, a plan or another message on the page, or when the page
    /// reaches the session's first record (`complete`).
    static func lastReply(_ records: [JSONValue], sessionID: String, turnID: String?, complete: Bool) -> String? {
        let mapper = AcpmuxRecords(sessionID: sessionID)
        let ordered = records.sorted { ($0["seq"]?.numberValue ?? 0) < ($1["seq"]?.numberValue ?? 0) }
        var message = ""
        var messageID: String?
        // Whether the current message's first chunk is on the page.
        var startKnown = false
        // Whether a record before the next chunk ends a message (so that chunk starts one).
        var boundary = complete
        var broken = true
        var ended = turnID == nil
        scan: for record in ordered {
            for event in mapper.map(record) {
                switch event {
                case .userMessage:
                    (message, messageID, startKnown, boundary, broken) = ("", nil, false, true, true)
                case .turnResult(let id, _, _, _) where id == turnID:
                    ended = true
                    break scan
                case .update(.agentMessageChunk(let text, let id)):
                    if broken || (id != nil && id != messageID) {
                        // Another message's chunks before this one also mark where it starts.
                        startKnown = boundary || !message.isEmpty
                        message = ""
                    }
                    message += text
                    messageID = id
                    broken = false
                case .update(.toolCall), .update(.toolCallUpdate), .update(.plan), .update(.agentThoughtChunk):
                    (broken, boundary) = (true, true)
                default:
                    break
                }
            }
        }
        guard ended, startKnown else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > replyLimit ? String(text.prefix(replyLimit)) + "…" : text
    }
}
