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

    static func plan(text: String, mode: NewTabIntent.Mode, agent: String?, resolver: OmniboxResolver,
                     home: URL? = FileManager.default.homeDirectoryForCurrentUser) -> NewTabSubmit {
        switch NewTabIntent.classify(text, mode: mode, home: home) {
        case .none: .page
        case .terminal(let command): .terminal(command: command)
        case .url(let address): URL(string: address).map(NewTabSubmit.browser) ?? .page
        case .search(let query): resolver.searchEngine.searchURL(for: query).map(NewTabSubmit.browser) ?? .page
        case .prompt(let prompt): .chat(prompt: prompt, harness: agent.flatMap { $0.isEmpty ? nil : $0 })
        }
    }
}

extension NewTabSubmit {
    /// Runs the action in the invocation's pane. The mode defaults to the
    /// one the user last left the screen in, else Ask.
    @MainActor
    static func run(_ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let pane = ctx.paneController(invocation) else { return }
        let services = ctx.services
        let text = invocation.arguments["text"]?.stringValue ?? ""
        let mode = invocation.arguments["mode"]?.stringValue.flatMap(NewTabIntent.Mode.init(rawValue:))
            ?? services.newTabChoices.mode.flatMap { NewTabIntent.Mode(rawValue: $0.rawValue) } ?? .ask
        let plan = plan(text: text, mode: mode, agent: invocation.arguments["agent"]?.stringValue,
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
            pane.showAgentTab(services.agentTabs.open(in: pane.paneKey, of: pane.daemon.store, seed: seed))
        }
    }
}
