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
    /// The card a recorded `user_message` draws (its `text`, `_meta.provenance` and `client`), or nil
    /// for the person's own prompt and anything not recognized, which then draws as written.
    public static func parse(text: String, provenance: JSONValue?, client: String? = nil, fromHarness: String? = nil) -> AgentIncoming? {
        // Only a record acpmux keeps as another agent's has its broker label read: anyone can type
        // one, and the person's own prompt stays theirs.
        let relay = fromAgent(provenance: provenance, client: client) ? RelayEnvelope(text) : nil
        let body = relay?.body ?? text
        let harness = provenance?["fromHarness"]?.nonEmpty ?? fromHarness
        let kind = provenance?["kind"]?.stringValue
        func one(_ name: String, _ words: String, id: String? = nil) -> AgentIncoming {
            // A message that signs itself (`[land-and-ci-c9] …`, `From lane-a: …`) names its sender
            // better than its envelope, unless the signature only repeats it (as the Mac's `agentSigned`).
            let signed = signature(words.trimmed, sender: name)
            return AgentIncoming(messages: [Message(sender: signed?.name ?? name, text: signed?.text ?? words.trimmed)],
                                 harness: harness, messageID: id ?? relay?.id, raw: text)
        }
        switch kind {
        case "inbox_notice":
            let messages = (provenance?["threads"]?.arrayValue ?? []).flatMap { thread -> [Message] in
                let from = thread["from"]?.arrayValue?.compactMap(\.nonEmpty).joined(separator: ", ") ?? ""
                if let recorded = thread["messages"]?.arrayValue, !recorded.isEmpty {
                    return recorded.compactMap { m in
                        guard let words = m["text"]?.stringValue else { return nil }
                        let sender = m["from"]?.nonEmpty ?? from
                        return signedMessage(sender, RelayEnvelope.without(words))
                    }
                }
                // The thread's preview, or (a notice logged before the provenance carried one) its line in the notice's text.
                let preview = [thread["preview"]?.nonEmpty, thread["threadId"]?.nonEmpty.flatMap { previewLine(text, threadID: $0) }]
                    .compactMap { $0.map(RelayEnvelope.withoutHead) }.first { !$0.isEmpty }
                guard let preview else { return [] }
                return [Message(sender: from, text: preview)]
            }
            // A notice that names no thread is bookkeeping: hidden, never the person's bubble.
            return AgentIncoming(messages: messages, raw: text)
        case "agent_digest":
            let messages = digest(body)
            if !messages.isEmpty { return AgentIncoming(messages: messages, harness: harness, raw: text) }
            // A digest whose parts don't read: one card from its senders, its text as sent (as the Mac).
            let senders = (provenance?["messages"]?.arrayValue ?? []).compactMap { $0["from"]?.nonEmpty }
            guard !senders.isEmpty else { break }
            var unique: [String] = []
            for sender in senders where !unique.contains(sender) { unique.append(sender) }
            let name = unique.count > 3 ? "\(unique.prefix(3).joined(separator: ", ")) +\(unique.count - 3)" : unique.joined(separator: ", ")
            return AgentIncoming(messages: [Message(sender: name, text: body.trimmed)], harness: harness, raw: text)
        case "subsession_message", "session_message", "task_result", "lane_report":
            guard let from = provenance?["from"]?.nonEmpty else { break }
            let name = provenance?["fromShortName"]?.nonEmpty ?? provenance?["fromName"]?.nonEmpty ?? from
            return one(name, body)
        case "agent_message":
            guard let from = provenance?["from"]?.nonEmpty else { break }
            let name = provenance?["fromName"]?.nonEmpty ?? from
            let msgID = provenance?["msgId"]?.nonEmpty
            return one(name, renderedBody(body, msgID: msgID) ?? body, id: msgID)
        case "notice":
            // A tool's or reconciler's notice: its sender, and its body without the rendered head and
            // Links line (the Mac's `noticeBody`).
            guard let name = provenance?["notice"]?["sender"]?.nonEmpty ?? provenance?["fromName"]?.nonEmpty
                ?? provenance?["from"]?.nonEmpty else { break }
            return AgentIncoming(messages: [Message(sender: name, text: noticeMarkdown(body, notice: provenance?["notice"]))],
                                 harness: harness, messageID: relay?.id, raw: text)
        default:
            // A kind this build doesn't know, from an agent's address (`acp:…`, or a named sender). A
            // kind it knows as the person's (`person_message`, `auto_resume`) stays theirs.
            if !knownKinds.contains(kind ?? ""), fromAgentAddress(provenance), let from = provenance?["from"]?.nonEmpty {
                return one(provenance?["fromName"]?.nonEmpty ?? from, body)
            }
        }
        return relay.map { one($0.sender, $0.body) }
    }

    /// Every provenance kind this build reads, the person's included (acpmux author.rs, hub/auto_resume.rs):
    /// only a kind outside it falls back on the sender's address.
    private static let knownKinds: Set<String> = agentKinds.union(["inbox_notice", "agent_digest", "person_message", "auto_resume"])

    /// Provenance kinds acpmux gives only another agent's message (or a tool's notice).
    private static let agentKinds: Set<String> = ["agent_message", "session_message", "subsession_message", "task_result", "lane_report", "notice"]

    /// Whether acpmux recorded the message as another agent's: its provenance says so, or (an older
    /// acpmux with none) it came by `acpmux send` at a shell, a peer or the outbox.
    static func fromAgent(provenance: JSONValue?, client: String?) -> Bool {
        if let provenance {
            let kind = provenance["kind"]?.stringValue
            return kind.map(agentKinds.contains) ?? false || (!knownKinds.contains(kind ?? "") && fromAgentAddress(provenance))
        }
        guard let client else { return false }
        return ["acpmux-cli#", "acpmux-peer#", "acpmux-outbox#"].contains { client.hasPrefix($0) }
    }

    /// A thread's line in an inbox notice's text, `- [blocker] N new in LABEL from A, B: PREVIEW (thread KEY)`: its preview.
    static func previewLine(_ notice: String, threadID: String) -> String? {
        let end = " (thread \(threadID))"
        guard let line = notice.split(separator: "\n").first(where: { $0.hasPrefix("- ") && $0.hasSuffix(end) }) else { return nil }
        let body = line.dropFirst(2).dropLast(end.count)
        guard let colon = body.range(of: ": ") else { return nil }
        return String(body[colon.upperBound...]).trimmed
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
        return out.map { signedMessage($0.sender, RelayEnvelope.without($0.text)) }
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
    /// A message under `sender`, or under the sender it signs itself with, without the signature.
    static func signedMessage(_ sender: String, _ text: String) -> Message {
        let signed = signature(text.trimmed, sender: sender)
        return Message(sender: signed?.name ?? sender, text: signed?.text ?? text.trimmed)
    }

    /// Whether a provenance's sender is an agent's address: another chat (`acp:<id>`) or a sender
    /// that named itself (`fromAgent`, the broker's `--from`).
    static func fromAgentAddress(_ provenance: JSONValue?) -> Bool {
        guard let from = provenance?["from"]?.stringValue else { return false }
        return from == "fromAgent" || from.hasPrefix("acp:")
    }

    /// The sender a message signs itself with and its text after the signature: `[from APP › PERSONA] …`,
    /// `[name] …` or `From name: …` (the Mac's `agentSigned`). A signature that only repeats `sender`
    /// keeps `sender`, the fuller name; nil when the text is not signed.
    static func signature(_ text: String, sender: String) -> (name: String, text: String)? {
        func groups(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
        func named(_ name: String, _ rest: String) -> (name: String, text: String)? {
            let rest = rest.trimmed
            guard !rest.isEmpty else { return nil }
            return (namesSender(name, sender) ? sender : name, rest)
        }
        if let label = groups(#"^\[from ([^\]\n]{1,110})\]\s+(\S[\s\S]*)$"#) {
            let name = label[0].split(separator: "›").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !name.isEmpty { return named(name, label[1]) }
        }
        if let bracket = groups(#"^\[([^\]\n]{1,64})\]\s+(\S[\s\S]*)$"#) {
            let name = bracket[0].trimmed
            if match(name, #"^[\w.@/:-]+(?: [\w.@/:-]+){0,3}$"#), !match(name, #"^(?:Request interrupted|Subagent hand-back|cmux agent message)"#),
               envelopeAgent(name) || namesSender(name, sender) {
                return named(name, bracket[1])
            }
        }
        if let from = groups(#"^From ([\w@/:-]+(?:\.[\w@/:-]+)*)[:.]\s+(\S[\s\S]*)$"#), envelopeAgent(from[0]) || namesSender(from[0], sender) {
            return named(from[0], from[1])
        }
        return nil
    }

    private static func match(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    /// An agent's name as envelopes write it: lowercase words joined by `-` or `/` (`land-and-ci-c9`,
    /// `build-box/lane-3`), never a person's (`Leo`).
    static func envelopeAgent(_ name: String) -> Bool {
        name == name.lowercased() && match(name, "[a-z]") && match(name, #"^[\w.@:]+(?:[-/][\w.@:]+)+$"#)
    }

    /// Whether `name` is the sender, or the sender on another machine (`<peer>/<name>`), ignoring
    /// case and runs of spaces.
    static func namesSender(_ name: String, _ sender: String) -> Bool {
        func folded(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let said = folded(name), full = folded(sender)
        guard !said.isEmpty, !full.isEmpty else { return false }
        return said == full || said == full.split(separator: "/").last.map(String.init) || full == said.split(separator: "/").last.map(String.init)
    }

    /// A notice as the card's Markdown: its title in bold, its body, then its links, from the
    /// provenance's `notice` (the rendered head and Links line are the same, written for the agent).
    static func noticeMarkdown(_ text: String, notice: JSONValue?) -> String {
        let title = notice?["title"]?.nonEmpty
        let links = (notice?["links"]?.arrayValue ?? []).compactMap { link -> String? in
            guard let url = link["url"]?.stringValue, url.hasPrefix("https://"), !url.contains(where: \.isWhitespace) else { return nil }
            let label = link["label"]?.nonEmpty?.replacingOccurrences(of: "]", with: "") ?? url
            return "[\(label)](\(url))"
        }
        // Without the structured parts, the notice reads as sent rather than losing them.
        guard let title else { return text.trimmed }
        let parts = ["**\(title)**", noticeLines(text), links.joined(separator: " · ")]
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A notice prompt's body without the rendered head (`[notice from SENDER( on HOST)?( · FIRE| · WARN)?] TITLE`)
    /// and the closing `Links: …` line, which the card doesn't draw (the Mac's `noticeBody`).
    static func noticeBody(_ text: String) -> String {
        let body = noticeLines(text)
        return body.isEmpty ? text.trimmed : body
    }

    /// The lines of a notice between its rendered head and Links line, empty when it has none.
    static func noticeLines(_ text: String) -> String {
        var lines = text.trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let first = lines.first, match(first, #"^\[notice from [\w.@/:-]{1,64}(?: on [A-Za-z0-9._-]{1,64})?(?: · (?:FIRE|WARN))?\][ \t]+\S"#) {
            lines.removeFirst()
        }
        if let last = lines.last, match(last.trimmed, #"^Links:[ \t]+https://\S+"#) { lines.removeLast() }
        return lines.joined(separator: "\n").trimmed
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
