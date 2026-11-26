import CmuxAgentCursor
import CmuxNextAgentCursor
import CmuxNextControl
import Foundation

/// Turns `cmux browser` page inputs (``BrowserPageAgentInput``) into the
/// `automation.input` events the agent cursor draws: one session per agent
/// name (`--agent NAME`, its own color and name tag), gap-free sequence
/// numbers per session, a drag's drop point in `to`.
struct PageInputCursorEvents {
    private var seqs: [String: UInt64] = [:]
    private let start: ContinuousClock.Instant

    init(start: ContinuousClock.Instant = .now) {
        self.start = start
    }

    /// The session an agent's inputs draw as: ``AgentCursorSessionLabel/cliSession``,
    /// with `:NAME` for a named agent.
    /// A known caller (`origin`) adds `|` and its tab id: two agents of one
    /// name in two workspaces draw two cursors, each with its own tag link.
    static func sessionID(agent: String?, origin: BrowserPageAgentOrigin? = nil) -> String {
        let name = (agent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let session = name.isEmpty && origin == nil ? AgentCursorSessionLabel.cliSession : AgentCursorSessionLabel.cliSession + ":" + name
        guard let origin else { return session }
        return session + String(AgentCursorSessionLabel.callerSeparator) + origin.tabID
    }

    /// The event and typing `input` draws as; nil for a pointer input with no measured element.
    mutating func event(for input: BrowserPageAgentInput, tabID: String) -> (AutomationInputEvent, AgentTyping?)? {
        let rect = input.rect.map { AutomationInputEvent.Rect(x: $0.x, y: $0.y, w: $0.width, h: $0.height) }
        let center = input.rect.map { AutomationInputEvent.Point(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
        let kind: AutomationInputEvent.Kind
        var typing: AgentTyping?
        var to: AutomationInputEvent.Point?
        switch input.kind {
        case .click, .select, .check: kind = .click
        case .hover, .focus: kind = .move
        case .scroll:
            kind = .scroll
            to = AutomationInputEvent.Point(x: 0, y: 0)
        case .drag:
            kind = .drag
            to = input.toRect.map { AutomationInputEvent.Point(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
            if to == nil { return nil }
        case .type:
            kind = .type
            typing = Self.typing(text: input.text, secret: input.secret, replace: input.replace)
        case .key:
            kind = .key
            guard let key = input.key, !key.isEmpty else { return nil }
            let printable = key.count == 1
            typing = AgentTyping(text: printable ? (input.secret ? "•" : key) : nil,
                                 key: printable && input.secret ? nil : key, masked: printable && input.secret)
        }
        if kind != .type && kind != .key, center == nil { return nil }
        let session = Self.sessionID(agent: input.agent, origin: input.origin)
        let seq = seqs[session, default: 0]
        seqs[session] = seq + 1
        let elapsed = ContinuousClock.now - start
        let tMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let event = AutomationInputEvent(
            sessionID: session, targetID: tabID, seq: seq, kind: kind, space: .viewport,
            point: kind == .type || kind == .key ? nil : center, rect: rect, to: to, tMs: tMs
        )
        // A select or check also shows what it set.
        if input.kind == .select { typing = Self.typing(text: input.text, secret: false, replace: true) }
        return (event, typing)
    }

    /// The caption text: dots for a field that hides its text, at most
    /// ``AgentTyping/maxTextLength`` characters (the end kept).
    static func typing(text: String?, secret: Bool, replace: Bool) -> AgentTyping? {
        guard let text, !text.isEmpty else { return nil }
        let shown = secret ? String(repeating: "•", count: min(text.count, AgentTyping.maxTextLength))
            : String(text.suffix(AgentTyping.maxTextLength))
        return AgentTyping(text: shown, masked: secret, replace: replace)
    }
}
