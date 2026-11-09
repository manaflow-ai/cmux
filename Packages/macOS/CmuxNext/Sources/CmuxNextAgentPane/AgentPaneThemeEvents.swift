import CmuxNextDesign
import Foundation

/// The `theme` event a page-host chat gets (``AgentPageEvent/theme(_:surface:)``), one per view, built again only
/// when what it is built from changed.
///
/// `applyTheme` runs on every move of the view (`viewDidMoveToWindow`), every New Tab adoption and every scope
/// change, and pushes only an event that differs from the last one the page got. Building the event to compare it
/// (`WebTheme.payloadJSON`, a JSON parse and `JSONValue(foundation:)`) cost a Cmd-T 2.4 ms of its key's turn for an
/// event equal to the last (TERMINAL CREATE COST, cmux19 Time Profiler, 2026-11-05). Its inputs are the web theme
/// (``WebTheme``, every field of its payload) and the pane's values (``AgentPaneTheme/values(_:motion:surface:)``,
/// the settings they read included), so equal inputs give the event built last.
@MainActor
final class AgentPaneThemeEvents {
    /// Events built from their inputs (tests count them).
    private(set) var builds = 0
    private var last: (web: WebTheme, agent: NSDictionary, event: AgentPageEvent)?

    /// The theme event for `tokens` on `surface`, in the caller's theme scope.
    func event(_ tokens: ThemeTokens, surface: SurfaceKind) -> AgentPageEvent? {
        let web = AgentPaneTheme.webTheme(tokens, surface: surface)
        let values = AgentPaneTheme.values(tokens, surface: surface)
        let agent = NSDictionary(dictionary: values.mapValues { $0 as Any })
        if let last, last.web == web, last.agent.isEqual(agent) { return last.event }
        builds += 1
        guard let event = AgentPageEvent.theme(web: web, agent: values) else { return nil }
        last = (web, agent, event)
        return event
    }
}
