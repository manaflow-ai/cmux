import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextSettings
import Foundation

/// `newTab.submit` (plans/cmux-next/new-tab.md section 5): the new tab
/// field's decision for the paths without a page (CLI `cmux tab
/// new-from-text`, its MCP tool, the palette). The same table as the field
/// (NewTabIntent), so a typed `!ls`, `github.com` or prompt opens the same
/// tab from any surface.
nonisolated enum NewTabSubmit: Equatable {
    /// Nothing typed: the new tab page itself.
    case page
    /// `!` first: a terminal with the command typed, never run.
    case terminal(command: String)
    case browser(URL)
    /// A prompt: an agent chat that sends it, on `harness` when given.
    case chat(prompt: String, harness: String?)

    static let action: ActionID = "newTab.submit"

    /// `search` is the explicit web-search choice (the field's search row):
    /// it searches any text but a `!` command (R86: no Search/Ask mode).
    static func plan(text: String, search: Bool, agent: String?, resolver: OmniboxResolver,
                     home: URL? = FileManager.default.homeDirectoryForCurrentUser) -> NewTabSubmit {
        switch NewTabIntent.classify(text, home: home) {
        case .none: return .page
        case .terminal(let command): return .terminal(command: command)
        case .url(let address) where !search: return URL(string: address).map(NewTabSubmit.browser) ?? .page
        case .prompt(let prompt) where !search: return .chat(prompt: prompt, harness: agent.flatMap { $0.isEmpty ? nil : $0 })
        case .url, .prompt:
            let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return resolver.searchEngine.searchURL(for: query).map(NewTabSubmit.browser) ?? .page
        }
    }
}

extension NewTabSubmit {
    /// Runs the action in the invocation's pane.
    @MainActor
    static func run(_ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let pane = ctx.paneController(invocation) else { return }
        let services = ctx.services
        let text = invocation.arguments["text"]?.stringValue ?? ""
        let search = invocation.arguments["search"]?.boolValue == true
        let plan = plan(text: text, search: search, agent: invocation.arguments["agent"]?.stringValue,
                        resolver: services.cache.suggestionEngine.resolver)
        let cwd = pane.selectedTab?.cwd
        switch plan {
        case .page:
            pane.newTabPage()
        case .terminal(let command):
            services.newTabKinds.record(.terminal, folder: cwd)
            pane.newTerminalTab(cwd: cwd, typing: command.isEmpty ? nil : command)
        case .browser(let url):
            services.newTabKinds.record(.browser(engine: nil), folder: cwd)
            pane.newBrowserTab(url: url)
        case .chat(let prompt, let harness):
            services.newTabKinds.record(.agent, folder: cwd)
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, prompt: prompt, harness: harness))
            pane.openAgentTab(seed: seed)
        }
    }
}
