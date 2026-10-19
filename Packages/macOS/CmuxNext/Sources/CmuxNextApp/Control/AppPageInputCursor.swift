import CmuxAgentCursor
import CmuxNextAgentCursor
import CmuxNextControl
import Foundation

/// The agent cursor for `cmux browser <tab> click|fill|type|press|…`
/// (`browser.page.*`): those commands run page scripts, so no browser host
/// event reports them; each one the service announces becomes one
/// `automation.input` event of the session ``sessionID`` for the tab, drawn
/// like a lease session's input (user, 2026-10-18: show what the agent
/// does "via cmux browser automation/CLI"). Off with `browser.showAgentCursor`.
@MainActor
final class AppPageInputCursor {
    /// The session the CLI's inputs draw as (one cursor color for them).
    static let sessionID = "cmux-browser-cli"

    private unowned let services: AppServices
    private var seq: UInt64 = 0
    private let start = ContinuousClock.now

    init(services: AppServices) {
        self.services = services
    }

    /// Draws `input` in tab `tabID` in every window that shows the tab.
    func publish(_ input: BrowserPageAgentInput, tabID: String) {
        guard services.settings?.snapshot.browserShowAgentCursor ?? true,
              let made = event(for: input, tabID: tabID) else { return }
        if let typing = made.1 {
            for slot in AgentCursorWiring.slots(in: services) { slot.noteTyping(typing, for: made.0) }
        }
        AgentCursorWiring.publish(made.0, in: services)
    }

    /// The event and typing `input` draws as; nil for a pointer input with no measured element.
    func event(for input: BrowserPageAgentInput, tabID: String) -> (AutomationInputEvent, AgentTyping?)? {
        let rect = input.rect.map { AutomationInputEvent.Rect(x: $0.x, y: $0.y, w: $0.width, h: $0.height) }
        let center = input.rect.map { AutomationInputEvent.Point(x: $0.x + $0.width / 2, y: $0.y + $0.height / 2) }
        let kind: AutomationInputEvent.Kind
        var typing: AgentTyping?
        switch input.kind {
        case .click, .select, .check: kind = .click
        case .hover, .focus: kind = .move
        case .scroll: kind = .scroll
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
        let elapsed = ContinuousClock.now - start
        let tMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let event = AutomationInputEvent(
            sessionID: Self.sessionID, targetID: tabID, seq: seq, kind: kind, space: .viewport,
            point: kind == .type || kind == .key ? nil : center, rect: rect,
            to: kind == .scroll ? AutomationInputEvent.Point(x: 0, y: 0) : nil, tMs: tMs
        )
        seq += 1
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
