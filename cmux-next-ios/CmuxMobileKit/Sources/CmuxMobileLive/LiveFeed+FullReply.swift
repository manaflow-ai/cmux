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
    /// The most characters a card keeps of a reply (the chat has the rest).
    static let replyLimit = 16_000

    /// Reads the whole reply of `item` (a finished turn of `sessionID`, whose
    /// record `through` is at or after its `turn_result`) and puts it on the card.
    func readFullReply(of item: FeedItem, sessionID: String, through seq: Int) {
        guard item.kind == .response, fullReplies[item.id] == nil, replyReads[item.id] == nil, let hub else { return }
        // task-owner: LiveFeed.replyReads: one transcript read per turn card; it ends with its request.
        replyReads[item.id] = Task { [weak self] in
            let page = try? await hub.request("_acpmux/events", .object([
                "sessionId": .string(sessionID),
                "beforeSeq": .number(Double(seq + 1)),
                "limit": .number(Double(Self.replyPage)),
                "kinds": .array([.string("transcript")]),
            ]), timeout: .seconds(20))
            guard let self else { return }
            replyReads[item.id] = nil
            guard let page else { return }
            let records = page["events"]?.arrayValue ?? []
            guard let reply = Self.lastReply(records, sessionID: sessionID, complete: records.count < Self.replyPage) else { return }
            fullReplies[item.id] = reply
            guard var current = store.item(id: item.id), current.kind == .response, current.markdown != reply else { return }
            log.info("feed reply \(item.id, privacy: .public): \(reply.count, privacy: .public) chars")
            current.markdown = reply
            store.upsert(current, atTop: false)
        }
    }

    /// The last agent message of the last turn in `records` (a transcript page,
    /// any order): its chunks joined, from the turn's prompt on. Nil when the
    /// page holds no reply, or holds only its end (the page was full and the
    /// turn's prompt is not on it: the start of the message may be missing).
    static func lastReply(_ records: [JSONValue], sessionID: String, complete: Bool) -> String? {
        let mapper = AcpmuxRecords(sessionID: sessionID)
        let ordered = records.sorted { ($0["seq"]?.numberValue ?? 0) < ($1["seq"]?.numberValue ?? 0) }
        var message = ""
        var messageID: String?
        var sawPrompt = false
        // Whether the next chunk starts a new message (after a tool call, a thought, a plan).
        var broken = true
        for record in ordered {
            for event in mapper.map(record) {
                switch event {
                case .userMessage:
                    (message, messageID, sawPrompt, broken) = ("", nil, true, true)
                case .update(.agentMessageChunk(let text, let id)):
                    if broken || (id != nil && id != messageID) { message = "" }
                    message += text
                    messageID = id
                    broken = false
                case .update(.toolCall), .update(.toolCallUpdate), .update(.plan), .update(.agentThoughtChunk):
                    broken = true
                default:
                    break
                }
            }
        }
        guard sawPrompt || complete else { return nil }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.count > replyLimit ? String(text.prefix(replyLimit)) + "…" : text
    }
}
