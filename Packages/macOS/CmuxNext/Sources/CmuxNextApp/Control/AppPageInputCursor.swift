import CmuxAgentCursor
import CmuxNextAgentCursor
import CmuxNextControl
import Foundation

/// The agent cursor for `cmux browser <tab> click|fill|type|press|drag|…`
/// (`browser.page.*`): those commands run page scripts, so no browser host
/// event reports them; each one the service announces becomes one
/// `automation.input` event (``PageInputCursorEvents``) for the tab, drawn
/// like a lease session's input, as its agent's own cursor and name tag
/// (`--agent NAME`; user, 2026-10-18/19: show what the agent does "via cmux
/// browser automation/CLI", "we need to show the mouse cursor"). Off with
/// `browser.showAgentCursor`.
@MainActor
final class AppPageInputCursor {
    /// The session an unnamed CLI agent's inputs draw as.
    static let sessionID = AgentCursorSessionLabel.cliSession

    private weak var services: AppServices?
    private var events = PageInputCursorEvents()

    init(services: AppServices) {
        self.services = services
    }

    /// Draws `input` in tab `tabID` in every window that shows the tab.
    func publish(_ input: BrowserPageAgentInput, tabID: String) {
        guard let services, services.settings?.snapshot.browserShowAgentCursor ?? true,
              let made = events.event(for: input, tabID: tabID) else { return }
        // The tag names who drives and where, and links there (before the first input draws it).
        if let origin = input.origin {
            services.agentCursorTagLinks.note(origin, agent: input.agent, session: made.0.sessionID)
        }
        if let typing = made.1 {
            for slot in AgentCursorWiring.slots(in: services) { slot.noteTyping(typing, for: made.0) }
        }
        AgentCursorWiring.publish(made.0, in: services)
    }
}
