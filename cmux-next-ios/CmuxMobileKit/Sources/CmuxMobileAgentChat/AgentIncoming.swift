import Foundation

/// A prompt another agent sent this chat, not the person's words: the card the transcript draws
/// in place of the person's bubble, its senders' messages without the envelopes acpmux and the
/// lane-gh broker put around them for the agent (Leo, 2026-11-05: "It probably shouldn't be
/// displaying it in that kind of raw way. Like we don't need to render it like this, in either
/// here nor the iOS thing."). The prompt as the agent got it stays `raw` (Copy as Sent). A port of
/// the Mac's `webviews/src/agent-session/acpmux/conversation/incomingMessage.ts` and
/// `relayEnvelope.ts`, case for case in `AgentIncomingTests`.
public struct AgentIncoming: Hashable, Sendable {
    public struct Message: Hashable, Sendable {
        /// The sender's name, as the chat knows it or as it named itself.
        public var sender: String
        /// What the sender wrote (Markdown).
        public var text: String

        public init(sender: String, text: String) {
            self.sender = sender
            self.text = text
        }
    }

    /// One message, or several that went in as one turn (a digest, an inbox notice), oldest first.
    public var messages: [Message]
    /// The sender's harness when acpmux names it (`fromHarness`), for its mark.
    public var harness: String?
    /// The message's short id when it has one (acpmux `msgId`, the broker's nonce), for the menu.
    public var messageID: String?
    /// The prompt as the agent got it.
    public var raw: String

    public init(messages: [Message], harness: String? = nil, messageID: String? = nil, raw: String) {
        self.messages = messages
        self.harness = harness
        self.messageID = messageID
        self.raw = raw
    }

    /// The card's title: its one sender, or the first three and a count.
    public var senders: String {
        var seen: [String] = []
        for message in messages where !seen.contains(message.sender) { seen.append(message.sender) }
        return seen.count > 3 ? "\(seen.prefix(3).joined(separator: ", ")) +\(seen.count - 3)" : seen.joined(separator: ", ")
    }

    /// Every message's text, for Copy and Find.
    public var text: String {
        messages.count == 1 ? messages[0].text : messages.map { "\($0.sender): \($0.text)" }.joined(separator: "\n\n")
    }
}

extension AgentIncoming {
    /// The card a recorded `user_message` draws (its `text` and `_meta.provenance`), or nil for the
    /// person's own prompt and anything not recognized, which then draws as written.
    public static func parse(text: String, provenance: JSONValue?, fromHarness: String? = nil) -> AgentIncoming? {
        let relay = RelayEnvelope(text)
        let body = relay?.body ?? text
        let harness = provenance?["fromHarness"]?.nonEmpty ?? fromHarness
        let kind = provenance?["kind"]?.stringValue
        func one(_ name: String, _ words: String, id: String? = nil) -> AgentIncoming {
            AgentIncoming(messages: [Message(sender: name, text: unsigned(words.trimmed, name))], harness: harness,
                          messageID: id ?? relay?.id, raw: text)
        }
        switch kind {
        case "inbox_notice":
            let messages = (provenance?["threads"]?.arrayValue ?? []).flatMap { thread -> [Message] in
                let from = thread["from"]?.arrayValue?.compactMap(\.nonEmpty).joined(separator: ", ") ?? ""
                if let recorded = thread["messages"]?.arrayValue, !recorded.isEmpty {
                    return recorded.compactMap { m in
                        guard let words = m["text"]?.stringValue else { return nil }
                        let sender = m["from"]?.nonEmpty ?? from
                        return Message(sender: sender, text: unsigned(RelayEnvelope.without(words).trimmed, sender))
                    }
                }
                guard let preview = thread["preview"]?.nonEmpty.map(RelayEnvelope.withoutHead), !preview.isEmpty else { return [] }
                return [Message(sender: from, text: preview)]
            }
            return messages.isEmpty ? nil : AgentIncoming(messages: messages, raw: text)
        case "agent_digest":
            let messages = digest(body)
            guard !messages.isEmpty else { break }
            return AgentIncoming(messages: messages, harness: harness, raw: text)
        case "subsession_message", "session_message", "task_result", "lane_report":
            guard let from = provenance?["from"]?.nonEmpty else { break }
            let name = provenance?["fromShortName"]?.nonEmpty ?? provenance?["fromName"]?.nonEmpty ?? from
            return one(name, body)
        case "agent_message", "notice":
            guard let from = provenance?["from"]?.nonEmpty else { break }
            let name = provenance?["fromName"]?.nonEmpty ?? from
            let msgID = provenance?["msgId"]?.nonEmpty
            return one(name, renderedBody(body, msgID: msgID) ?? body, id: msgID)
        default:
            break
        }
        return relay.map { one($0.sender, $0.body) }
    }

    /// The messages of a digest as acpmux writes it (hub/digest.rs `digest_blocks`): a line saying
    /// what follows, then each message under `[agent message 2 of 3] from <sender>`.
    static func digest(_ text: String) -> [Message] {
        var current: Message?
        var out: [Message] = []
        var started = false
        for line in text.trimmed.split(separator: "\n", omittingEmptySubsequences: false) {
            if let sender = digestSender(line) {
                if let message = current { out.append(message) }
                current = Message(sender: sender, text: "")
                started = true
            } else if var message = current {
                message.text += message.text.isEmpty ? String(line) : "\n\(line)"
                current = message
            } else if !started, !line.trimmingCharacters(in: .whitespaces).isEmpty, !line.contains("messages from other agents arrived"),
                      !line.contains("message from other agents arrived") {
                return []
            }
        }
        if let message = current { out.append(message) }
        return out.map { Message(sender: $0.sender, text: unsigned(RelayEnvelope.without($0.text).trimmed, $0.sender)) }
    }

    private static func digestSender(_ line: Substring) -> String? {
        guard line.hasPrefix("[agent message "), let close = line.range(of: "] from ") else { return nil }
        let count = line[line.index(line.startIndex, offsetBy: 15)..<close.lowerBound].split(separator: " ")
        guard count.count == 3, count[1] == "of", Int(count[0]) != nil, Int(count[2]) != nil else { return nil }
        let sender = line[close.upperBound...].trimmingCharacters(in: .whitespaces)
        return sender.isEmpty ? nil : sender
    }

    /// The sender's words in a message as cmux renders it for the agent (agent_message_prompt.rs
    /// `render`): a header, `Message id: <id>`, notes, `---`, the body, `--- end of message <id> ---`.
    /// The closing line must name the provenance's id, so a body cannot end its message early.
    static func renderedBody(_ text: String, msgID: String?) -> String? {
        guard let msgID else { return nil }
        let lines = text.trimmed.components(separatedBy: "\n")
        guard lines.count >= 4, lines[0].hasPrefix("[cmux agent message"), lines[1] == "Message id: \(msgID)",
              lines.last == "--- end of message \(msgID) ---", let rule = lines.firstIndex(of: "---"), rule < lines.count - 1
        else { return nil }
        return lines[(rule + 1)..<(lines.count - 1)].joined(separator: "\n")
    }

    /// `text` without a signature that only repeats the sender (`[lane-a] Merged`, `From lane-a: Merged`).
    static func unsigned(_ text: String, _ name: String) -> String {
        let short = name.split(separator: "/").last.map(String.init) ?? name
        for said in [name, short] where !said.isEmpty {
            for prefix in ["[\(said)] ", "From \(said): ", "From \(said). "] where text.lowercased().hasPrefix(prefix.lowercased()) {
                let rest = text.dropFirst(prefix.count).trimmed
                if !rest.isEmpty { return rest }
            }
        }
        return text
    }
}

/// The label the lane-gh broker puts around a lane VM's message (leo-workspace
/// machines/lane-gh-broker.json, action send): `[message N from VM/LANE (an agent, not Leo),
/// relayed by the lane-gh broker; its text ends at "[end of message N]"]`, the text, then `[end of
/// message N]`, with a fresh nonce N. Only a last line naming the head's own nonce closes it.
struct RelayEnvelope: Hashable, Sendable {
    var id: String
    var sender: String
    var body: String

    private static let notLeo = " (an agent, not Leo), relayed by "

    init(id: String, sender: String, body: String) {
        self.id = id
        self.sender = sender
        self.body = body
    }

    init?(_ text: String) {
        let trimmed = text.trimmed
        guard let newline = trimmed.firstIndex(of: "\n") else { return nil }
        let head = trimmed[..<newline].trimmingCharacters(in: .whitespaces)
        guard let parsed = Self.head(head) else { return nil }
        let closing = "[end of message \(parsed.id)]"
        guard trimmed.hasSuffix(closing) else { return nil }
        let end = trimmed.index(trimmed.endIndex, offsetBy: -closing.count)
        // The closing marker is a line of its own; one written inline is the body's own text.
        guard end > newline, trimmed[trimmed.index(before: end)] == "\n" else { return nil }
        id = parsed.id
        sender = parsed.sender
        body = trimmed[trimmed.index(after: newline)..<end].trimmed
    }

    /// The nonce and sender of a whole head line.
    private static func head(_ line: String) -> (id: String, sender: String)? {
        guard line.hasPrefix("[message "), let from = line.range(of: " from "), let label = line.range(of: notLeo),
              from.upperBound <= label.lowerBound else { return nil }
        let id = String(line[line.index(line.startIndex, offsetBy: 9)..<from.lowerBound])
        guard (4...64).contains(id.count), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let sender = line[from.upperBound..<label.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !sender.isEmpty, !sender.contains("\n") else { return nil }
        guard line.hasSuffix("; its text ends at \"[end of message \(id)]\"]") else { return nil }
        return (id, sender)
    }

    /// `text` without a broker label around it, else as written.
    static func without(_ text: String) -> String { RelayEnvelope(text)?.body ?? text }

    /// A one-line preview without the broker's head before the message's first words.
    static func withoutHead(_ preview: String) -> String {
        guard preview.hasPrefix("[message "), let close = preview.range(of: "\"]") else { return preview }
        guard let parsed = Self.head(String(preview[..<close.upperBound])) else { return preview }
        let rest = preview[close.upperBound...].trimmed
        let closing = "[end of message \(parsed.id)]"
        return rest.hasSuffix(closing) ? rest.dropLast(closing.count).trimmed : rest
    }
}

private extension JSONValue {
    var nonEmpty: String? {
        guard let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
