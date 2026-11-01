import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextMacScreen
import CmuxNextSettings
import Foundation
import enum CmuxNextLayout.ChatColumnPlacement

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
    /// Nothing opens; the person reads why (a pairing link: Mac Screen's refusal).
    case refused(String)

    static let action: ActionID = "newTab.submit"

    /// `search` is the explicit web-search choice (the field's search row):
    /// it searches any text but a `!` command (R86: no Search/Ask mode).
    /// `fixesHostTypos`: the user typed the text (the palette), so a
    /// top-level-domain typo is fixed as the omnibar fixes it
    /// (`OmniboxResolver.commitTypoFix`); never for CLI, MCP or scripts.
    static func plan(text: String, search: Bool, agent: String?, resolver: OmniboxResolver,
                     home: URL? = FileManager.default.homeDirectoryForCurrentUser, fixesHostTypos: Bool = false) -> NewTabSubmit {
        let intent = NewTabIntent.classify(text, home: home)
        switch intent {
        case .url, .prompt:
            if fixesHostTypos, !search, let fixed = resolver.commitTypoFix(for: text) { return .browser(fixed) }
        case .none, .terminal, .refused:
            break
        }
        switch intent {
        case .none: return .page
        case .refused: return .refused(MacScreenPages.pairingLinkRefusal)
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
    /// Classify before choosing a pane, so native Browser picks keep the submission table's commands,
    /// searches and typo fixes. Explicit Terminal picks keep their Run intent.
    static func nativeRequest(text: String, kind: AgentPaneTabKind, search: Bool, cwd: String?, resolver: OmniboxResolver) -> AgentPaneOpenTab? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var request = AgentPaneOpenTab(kind: kind, text: trimmed, cwd: cwd, search: search, run: kind == .terminal)
        guard kind == .browser, !trimmed.isEmpty else { return request }
        switch plan(text: trimmed, search: search, agent: nil, resolver: resolver, fixesHostTypos: true) {
        case .terminal(let command): request.kind = .terminal; request.text = command
        case .chat: request.search = true
        case .browser(let url): request.text = url.absoluteString; request.search = false
        case .refused: return nil
        case .page: break
        }
        return request
    }

    /// Whether what this submission opens is a tool that goes beside the chat, never into the chat dock: a
    /// terminal or a browser. The page, a chat and a refusal stay where they were asked for.
    var opensBesideChat: Bool {
        switch self {
        case .terminal, .browser: true
        case .page, .chat, .refused: false
        }
    }

    /// ``opensBesideChat`` for a submission from `origin`: only a person's moves beside the chat; a script's
    /// (CLI `tab new-from-text`, MCP) opens in the pane it named.
    func opensBesideChat(origin: ActionOrigin) -> Bool { origin == .user && opensBesideChat }

    /// The `openBrowser` run that opens `url` for `invocation`: the same
    /// target and origin, so openBrowser's guard (agents never open
    /// Chromium's own pages, CLI/MCP/script tabs are agent-driven) covers
    /// this action too.
    static func browserInvocation(_ url: URL, from invocation: ActionInvocation) -> ActionInvocation? {
        var open = ActionInvocation(target: invocation.target, arguments: ["url": .string(url.absoluteString)],
                                    origin: invocation.origin, focusRequested: invocation.focusRequested)
        open.keyContext = invocation.keyContext
        return open
    }

    /// Runs the action in the invocation's pane.
    @MainActor
    static func run(_ invocation: ActionInvocation, _ ctx: AppActionContext) {
        guard let pane = ctx.paneController(invocation) else { return }
        let services = ctx.services
        let text = invocation.arguments["text"]?.stringValue ?? ""
        let search = invocation.arguments["search"]?.boolValue == true
        let plan = plan(text: text, search: search, agent: invocation.arguments["agent"]?.stringValue,
                        resolver: services.cache.suggestionEngine.resolver, fixesHostTypos: invocation.origin == .user)
        let cwd = pane.selectedTab?.cwd
        switch plan {
        case .page:
            pane.newTabPage(reusingShown: true)
        case .refused(let reason):
            services.registry.refuse(reason)
        case .terminal(let command):
            // From the chat dock, the main pane, the terminal opens in the strip beside it (Leo 2026-10-30: "not to
            // fucking open it up in the main fucking pane"); a browser does through openBrowser's own route. Review
            // of #28544 at 39fa77d8: `!ls` typed on the native page as a prompt made its terminal in the dock.
            // Only a person's submission moves: a script's (CLI, MCP) aimed at the dock opens where it asked, as in
            // TabLifecycle (delta review of #28544 at 54e3d1bf).
            let chatPlacement = ChatColumnPlacement.keepsNewTabPage(in: pane) || NewTabPage.docksChat(pane)
            guard plan.opensBesideChat(origin: invocation.origin) && chatPlacement else {
                pane.newTerminalTab(cwd: cwd, typing: command.isEmpty ? nil : command)
                return
            }
            services.linkOpener.open(from: pane, kind: .terminal) { target, placed in
                target.newTerminalTab(cwd: cwd, typing: command.isEmpty ? nil : command, placementOwner: placed != nil) { surface in placed?(surface) }
                return true
            }
        case .browser(let url):
            if invocation.origin == .user, ChatColumnPlacement.isBelowChat(pane) { _ = pane.newBrowserTab(url: url, engine: BrowserEngineTag.engine(for: url)); return }
            guard let open = browserInvocation(url, from: invocation) else { return }
            TabLifecycle.newBrowser(ctx, open)
        case .chat(let prompt, let harness):
            // The prompt goes out by itself only when a person typed it here (palette, menu);
            // a CLI, MCP or script prompt waits in the composer for a Send (cx-k21v gap 4).
            let seed = AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, prompt: prompt,
                                                         promptBy: invocation.origin == .user ? .person : .automation,
                                                         harness: harness))
            pane.openAgentTab(seed: seed)
        }
    }
}
