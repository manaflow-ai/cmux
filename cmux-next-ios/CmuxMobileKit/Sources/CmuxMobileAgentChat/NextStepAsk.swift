import Foundation

/// A question an agent asks in its own words at the end of a turn, tagged the way the Mac's agent
/// pane reads it (`[taste]`, `[outward]`, `[irreversible]`, `[physical]`, `[for you]`): the
/// transcript draws it as a card with its answers as buttons, and a tap sends the answer as the next
/// prompt. A port of the Mac's `webviews/src/agent-session/acpmux/conversation/nextStepAsk.ts`
/// (#33269), as strict: a card only where the agent asked exactly one tagged question with answers
/// to tap, never for ordinary prose.
public struct NextStepAsk: Equatable, Sendable {
    /// One answer button: what it sends, and whether the card made it up (Yes and Not now for a
    /// yes-or-no question), which it draws in the phone's own words.
    public struct Option: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case listed, yes, notNow }
        public var label: String
        public var kind: Kind

        /// The button's title: the agent's own words, or the phone's for a made-up answer.
        public var title: String {
            switch kind {
            case .listed: label
            case .yes: String(localized: "Yes")
            case .notNow: String(localized: "Not now")
            }
        }
    }

    /// The tag the line carried, lowercased ("outward").
    public var tag: String
    /// The question, through its last question mark, without the tag or a "For Leo:" lead.
    public var question: String
    /// What the line said after the question ("My pick: yes."), muted under it.
    public var detail: String?
    /// Two to four answers; the first is the primary.
    public var options: [Option]
    /// The answer's text without the ask's lines, which the card draws instead.
    public var rest: String

    static let tags = ["taste", "outward", "irreversible", "physical", "for you"]
    static let maxLabel = 80
    static let maxOptions = 4

    nonisolated(unsafe) private static let tagged = try? NSRegularExpression(
        pattern: #"^\s{0,3}(?:[-*+]\s+|\d{1,2}[.)]\s+)?(?:\*\*|__)?\[(taste|outward|irreversible|physical|for you)\](?:\*\*|__)?:?\s+(.+?)\s*$"#,
        options: [.caseInsensitive])
    nonisolated(unsafe) private static let lead = try? NSRegularExpression(
        pattern: #"^(?:(?:\*\*)?for\s+(?:leo|you)(?:\*\*)?\s*:\s*|leo\s*:\s*)"#, options: [.caseInsensitive])
    nonisolated(unsafe) private static let listItem = try? NSRegularExpression(pattern: #"^\s{0,3}(?:[-*+]|\d{1,2}[.)])\s+(.+?)\s*$"#)
    nonisolated(unsafe) private static let fence = try? NSRegularExpression(pattern: #"^\s{0,3}(```|~~~)"#)
    nonisolated(unsafe) private static let yesNo = try? NSRegularExpression(
        pattern: #"^(?:should|shall|may|can|could|do|does|did|is|are|was|were|will|would|want|ok|okay|go ahead|proceed|merge|land|approve)\b"#,
        options: [.caseInsensitive])

    /// The tagged ask at the end of `text`, or nil when there is none or it is not clear enough to
    /// draw: exactly one tagged line that asks a question (a question mark outside code), not in a
    /// code block or a quote, followed by two to four short answers, or none for a yes-or-no
    /// question (then Yes and Not now).
    public static func parse(_ text: String) -> NextStepAsk? {
        guard text.contains("["), let tagged, let lead, let listItem, let fence, let yesNo else { return nil }
        let lines = text.components(separatedBy: "\n")
        var fenced = false
        var found: [(at: Int, tag: String, body: String)] = []
        for (at, line) in lines.enumerated() {
            if matches(fence, line) {
                fenced.toggle()
                continue
            }
            if fenced || matches(Self.quote, line) { continue }
            guard let groups = capture(tagged, line), groups.count == 2 else { continue }
            // A question mark inside inline code is not the question's.
            guard outsideCode(groups[1]).contains("?") else { continue }
            found.append((at, groups[0].lowercased(), groups[1]))
        }
        guard found.count == 1, let ask = found.first else { return nil }
        let body = replacingFirst(lead, in: ask.body)
        guard let end = lastQuestionMark(body) else { return nil }
        let asked = String(body[...end]).trimmingCharacters(in: .whitespaces)
        let question = asked.prefix(1).uppercased() + asked.dropFirst()
        let after = String(body[body.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        // The answers: a list right under the line, one blank line between allowed.
        var next = ask.at + 1
        if next < lines.count, lines[next].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           next + 1 < lines.count, matches(listItem, lines[next + 1]) {
            next += 1
        }
        var items: [String] = []
        var stop = next
        while stop < lines.count, let item = capture(listItem, lines[stop])?.first {
            items.append(plainLabel(item))
            stop += 1
        }
        var options: [Option]
        var last = ask.at
        if !items.isEmpty {
            guard (2...maxOptions).contains(items.count), !items.contains(where: { $0.isEmpty || $0.count > maxLabel }) else { return nil }
            options = items.map { Option(label: $0, kind: .listed) }
            last = stop - 1
        } else if matches(yesNo, asked) {
            // What the agent reads is English (the prompt); the buttons draw the phone's words.
            options = [Option(label: "Yes", kind: .yes), Option(label: "Not now", kind: .notNow)]
        } else {
            return nil
        }
        // One blank line stays where the ask's lines were between two paragraphs.
        var tail = Array(lines[(last + 1)...])
        if ask.at > 0, lines[ask.at - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           tail.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            tail.removeFirst()
        }
        var rest = (Array(lines[..<ask.at]) + tail).joined(separator: "\n")
        while let scalar = rest.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(scalar) { rest.removeLast() }
        return NextStepAsk(tag: ask.tag, question: question, detail: after.isEmpty ? nil : after, options: options, rest: rest)
    }

    /// The answer the person gave: the option their next prompt chose (case and outer space
    /// aside), else that prompt's first line, so a typed answer reads too.
    public func chosenAnswer(_ reply: String) -> String {
        let said = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let picked = options.first(where: { $0.label.caseInsensitiveCompare(said) == .orderedSame }) { return picked.title }
        let first = said.components(separatedBy: "\n").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.count > 120 ? String(first.prefix(119)) + "…" : first
    }

    nonisolated(unsafe) private static let quote = try? NSRegularExpression(pattern: #"^\s{0,3}>"#)

    private static func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// The capture groups of the first match (empty strings for groups that did not take part).
    private static func capture(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: line).map { String(line[$0]) } ?? ""
        }
    }

    private static func replacingFirst(_ regex: NSRegularExpression, in text: String) -> String {
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }

    /// The text with inline code spans blanked, so their question marks do not count.
    private static func outsideCode(_ text: String) -> String {
        var out = ""
        var inCode = false
        for character in text {
            if character == "`" { inCode.toggle(); continue }
            if !inCode { out.append(character) }
        }
        return out
    }

    private static func lastQuestionMark(_ text: String) -> String.Index? {
        var inCode = false
        var found: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" { inCode.toggle() } else if character == "?", !inCode { found = index }
            index = text.index(after: index)
        }
        return found
    }

    private static func plainLabel(_ text: String) -> String {
        var label = text.trimmingCharacters(in: .whitespaces)
        for wrap in ["**", "__", "`"] where label.count > wrap.count * 2 && label.hasPrefix(wrap) && label.hasSuffix(wrap) {
            label = String(label.dropFirst(wrap.count).dropLast(wrap.count))
            break
        }
        return label.trimmingCharacters(in: .whitespaces)
    }
}
