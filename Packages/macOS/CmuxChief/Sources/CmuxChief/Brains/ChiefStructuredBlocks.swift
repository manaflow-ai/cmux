public import CmuxAgentQuestion
import Foundation

/// The result of a finished Chief flow, shown as a card with one action.
///
/// Today the only action opens a Cloud machine workspace
/// (`cmux vm workspace open <machine> <workspace>`); the card stores as a
/// `MessagePart.work` whose `host` is the machine and whose `session` is the
/// machine workspace id, so it survives in every Home client unchanged.
public struct ChiefResultCard: Sendable, Equatable, Codable {
    /// What the agent or the flow reached.
    public enum Status: String, Sendable, Equatable, Codable {
        /// The agent in the workspace was seen working.
        case working
        /// The workspace is ready; nothing runs in it yet.
        case ready
        /// The flow failed; the subtitle says why.
        case failed
        /// The agent waits for the user to sign in on the machine; the subtitle says how.
        case needsSignIn = "needs_sign_in"
    }

    public var title: String
    public var subtitle: String?
    /// The machine id (`brave-otter`).
    public var machine: String
    /// The machine workspace id (`ws_…`).
    public var workspace: String
    public var status: Status

    public init(title: String, subtitle: String? = nil, machine: String, workspace: String, status: Status = .ready) {
        self.title = title
        self.subtitle = subtitle
        self.machine = machine
        self.workspace = workspace
        self.status = status
    }
}

/// Lifts the Chief's structured blocks out of its streamed reply text.
///
/// The model writes a block as a fenced code block whose info string names
/// it, with one JSON object inside:
///
/// ````
/// ```cmux-question
/// {"submit": "Create", "questions": [{"id": "size", "header": "Size",
///   "prompt": "Create a cloud machine?", "options": [{"id": "8g",
///   "label": "8 GB", "detail": "4 vCPU · included in your Pro plan"}]}]}
/// ```
/// ````
///
/// ````
/// ```cmux-result
/// {"title": "Codex is working on brave-otter", "subtitle": "fix login · ws_4f2c",
///  "machine": "brave-otter", "workspace": "ws_4f2c", "status": "working"}
/// ```
/// ````
///
/// The text around a block streams as usual; the block itself never shows as
/// text. While a fence may be opening (a trailing "`", "``", …) the text is
/// held back, so a draft never flashes the raw JSON. A block whose JSON does
/// not parse, or one the reply never closes, falls back to its text.
///
/// Pure state, shared by the Claude Code and Codex parsers.
struct ChiefStructuredBlocks: Sendable {
    /// One recognized block.
    enum Block: Sendable, Equatable {
        case question(AgentQuestion)
        case result(ChiefResultCard)
    }

    /// One piece of filtered output, in order.
    enum Piece: Sendable, Equatable {
        case text(String)
        case block(Block)
    }

    static let questionKind = "cmux-question"
    static let resultKind = "cmux-result"
    private static let opener = "```cmux-"

    /// The Chief's session id, recorded as the question's source.
    var session: String?
    /// Mints a question id (tests pin it).
    var makeID: @Sendable () -> String = { "chief-question-" + UUID().uuidString.lowercased() }

    /// Text not yet emitted: a possible fence start, or an open block's body.
    private var pending = ""
    /// The kind of the open block, after its opener line was read.
    private var openKind: String?

    init(session: String? = nil) {
        self.session = session
    }

    /// Forgets a half-read block (a new turn, a stopped one).
    mutating func reset() {
        pending = ""
        openKind = nil
    }

    // MARK: Turn events

    /// Filters one brain event: text deltas lose their blocks (which become
    /// `.question` / `.result` events in place); any event that ends the
    /// text segment first flushes held-back text.
    mutating func filter(_ event: ChiefTurnEvent) -> [ChiefTurnEvent] {
        switch event {
        case .textDelta(let text):
            return feed(text).map(Self.event)
        case .textSegmentEnd, .toolStarted, .approvalRequested, .question, .result, .finished, .failed:
            return finish().map(Self.event) + [event]
        case .session, .toolFinished, .usage:
            return [event]
        }
    }

    private static func event(_ piece: Piece) -> ChiefTurnEvent {
        switch piece {
        case .text(let text): return .textDelta(text)
        case .block(.question(let question)): return .question(question)
        case .block(.result(let card)): return .result(card)
        }
    }

    // MARK: Text

    /// Reads more reply text.
    mutating func feed(_ text: String) -> [Piece] {
        pending += text
        var out: [Piece] = []
        while true {
            if let kind = openKind {
                guard let close = Self.closingFence(in: pending) else { break }
                let body = String(pending[..<close.lowerBound])
                pending = String(pending[close.upperBound...])
                openKind = nil
                if let block = parse(kind: kind, body: body) {
                    out.append(.block(block))
                } else {
                    out.append(.text("```\(kind)\n\(body)```"))
                }
                continue
            }
            guard let start = pending.range(of: Self.opener) else {
                let hold = Self.heldSuffix(pending)
                let emit = String(pending.dropLast(hold))
                if !emit.isEmpty { out.append(.text(emit)) }
                pending = String(pending.suffix(hold))
                break
            }
            guard let newline = pending[start.upperBound...].firstIndex(of: "\n") else {
                // The opener line is not complete yet.
                let before = String(pending[..<start.lowerBound])
                if !before.isEmpty { out.append(.text(before)) }
                pending = String(pending[start.lowerBound...])
                break
            }
            let name = "cmux-" + pending[start.upperBound..<newline].trimmingCharacters(in: .whitespaces)
            let before = String(pending[..<start.lowerBound])
            let afterOpener = pending.index(after: newline)
            if name == Self.questionKind || name == Self.resultKind {
                if !before.isEmpty { out.append(.text(before)) }
                openKind = name
                pending = String(pending[afterOpener...])
            } else {
                // Some other `cmux-…` code block: ordinary text.
                out.append(.text(String(pending[..<afterOpener])))
                pending = String(pending[afterOpener...])
            }
        }
        return out
    }

    /// The segment ended: held-back text, or an unclosed block as text.
    mutating func finish() -> [Piece] {
        defer { reset() }
        if let kind = openKind {
            // The reply ended inside the block, or on its closing fence with no newline after it.
            var body = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.hasSuffix("```") { body = String(body.dropLast(3)) }
            if let block = parse(kind: kind, body: body) { return [.block(block)] }
            return [.text("```\(kind)\n\(pending)")]
        }
        return pending.isEmpty ? [] : [.text(pending)]
    }

    /// The closing fence: "```" at the start of a line, through the end of its line.
    private static func closingFence(in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let fence = text.range(of: "```", range: search..<text.endIndex) {
            let atLineStart = fence.lowerBound == text.startIndex || text[text.index(before: fence.lowerBound)] == "\n"
            if atLineStart {
                // Wait for the fence line's end so "````" or trailing text is not split.
                guard let end = text[fence.upperBound...].firstIndex(of: "\n") else { return nil }
                return fence.lowerBound..<text.index(after: end)
            }
            search = fence.upperBound
        }
        return nil
    }

    /// How many trailing characters could start a block opener.
    private static func heldSuffix(_ text: String) -> Int {
        let opener = Array(Self.opener)
        let chars = Array(text.suffix(opener.count - 1))
        for length in stride(from: chars.count, through: 1, by: -1) where Array(chars.suffix(length)) == Array(opener.prefix(length)) {
            return length
        }
        return 0
    }

    // MARK: Blocks

    private func parse(kind: String, body: String) -> Block? {
        guard let json = try? ChiefJSON(parsing: Data(body.utf8)) else { return nil }
        switch kind {
        case Self.questionKind:
            return Self.question(json, id: makeID(), session: session ?? "chief").map(Block.question)
        case Self.resultKind:
            return Self.result(json).map(Block.result)
        default:
            return nil
        }
    }

    /// A `cmux-question` body: `{"submit"?, "questions": [item…]}`, or one
    /// item at the top level. An item is `{"id"?, "header"?, "prompt",
    /// "options": [{"id"?, "label", "detail"?}], "multi_select"?, "allows_other"?}`;
    /// a Chief card allows no free-text answer unless `allows_other` says so.
    static func question(_ json: ChiefJSON, id: String, session: String) -> AgentQuestion? {
        let raw = json["questions"]?.array ?? [json]
        let items = raw.enumerated().compactMap { index, item -> AgentQuestion.Item? in
            guard let prompt = nonEmpty(item["prompt"]?.string) else { return nil }
            let options = (item["options"]?.array ?? []).enumerated().compactMap { optionIndex, option -> AgentQuestion.Option? in
                guard let label = nonEmpty(option["label"]?.string) else { return nil }
                return AgentQuestion.Option(id: nonEmpty(option["id"]?.string) ?? "o\(optionIndex)", label: label,
                                            detail: nonEmpty(option["detail"]?.string))
            }
            guard !options.isEmpty else { return nil }
            return AgentQuestion.Item(id: nonEmpty(item["id"]?.string) ?? "q\(index)", header: nonEmpty(item["header"]?.string),
                                      prompt: prompt, options: options,
                                      multiSelect: (item["multi_select"] ?? item["multiSelect"])?.bool ?? false,
                                      allowsOther: (item["allows_other"] ?? item["allowsOther"])?.bool ?? false)
        }
        guard !items.isEmpty, items.count <= 4 else { return nil }
        // Item ids must be distinct: the answer is keyed by them.
        guard Set(items.map(\.id)).count == items.count else { return nil }
        let source = AgentQuestion.Source(harness: .chief, session: session, agentName: "Chief")
        return AgentQuestion(id: id, source: source, items: items, submitLabel: nonEmpty(json["submit"]?.string))
    }

    /// A `cmux-result` body: `{"title", "subtitle"?, "machine", "workspace", "status"?}`.
    static func result(_ json: ChiefJSON) -> ChiefResultCard? {
        guard let title = nonEmpty(json["title"]?.string), let machine = nonEmpty(json["machine"]?.string),
              let workspace = nonEmpty(json["workspace"]?.string) else { return nil }
        let status = json["status"]?.string.flatMap(ChiefResultCard.Status.init(rawValue:)) ?? .ready
        return ChiefResultCard(title: title, subtitle: nonEmpty(json["subtitle"]?.string), machine: machine,
                               workspace: workspace, status: status)
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
