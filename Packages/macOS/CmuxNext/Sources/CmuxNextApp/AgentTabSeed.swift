import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextBrowser
import CmuxNextDaemonService
import Foundation

extension AppActionContext {
    /// Terminal text to a chat (``TerminalToChatActions``): after the draft of the workspace's agent chat the person
    /// focused last (``WorkContextTrail``), else as the draft of a new chat beside the terminal, in its folder.
    func draftInChat(_ markdown: String, from invocation: ActionInvocation) {
        guard let (tab, pane) = daemonTab(invocation) else { return }
        if let chat = services.inheritedWork(besides: tab, in: pane, kinds: [.chat], value: { $0.id }),
           services.revealTab(chat), let view = services.agentTabs.existingView(chat) {
            return view.appendToDraft(markdown)
        }
        guard let pane = services.paneController(for: pane) else { return refuse(RefusalStrings.notShownInAnyWindow(tab.id)) }
        _ = pane.openAgentTab(seed: AgentPaneSeedSource(AgentPaneSeed(cwd: tab.cwd, draft: markdown, harness: pane.inheritedHarness())))
    }
}

extension PaneController {
    /// The seed for a chat opened from the selected tab: a terminal's cwd
    /// and selection, a page's title, URL and selection. Its folder and harness are the ones the
    /// person works in (NEW-WORK-INHERITS-CONTEXT, ``WorkContextTrail``): the folder of the
    /// selected terminal or chat, else of the terminal or chat focused last in this workspace
    /// (then in the window, for a workspace with none); the harness of the chat focused last.
    /// Nil when there is nothing to inherit.
    func agentSeedFromSelectedTab() -> AgentPaneSeedSource? {
        let cwd = NewTerminalStart.inherited(besides: selectedTab, in: pane, services: services)
        let harness = inheritedHarness()
        switch currentContent {
        case .terminal(let entry):
            let selection = entry.session.surfaceView.accessibilitySelectedText()
            return AgentPaneSeedSource(AgentPaneSeed(cwd: cwd ?? selectedTab?.cwd, draft: AgentPaneSeed.terminalDraft(selection: selection),
                                                     harness: harness))
        case .browser(let entry):
            let page = entry.tab
            let title = page.state.title
            let url = page.state.url
            // A page has no cwd: the folder of the terminal or chat focused last, else the pane's
            // last terminal tab's, in strip order.
            let pageCwd = cwd ?? pane.tabs.last { $0.kind == .pty && $0.cwd != nil }?.cwd
            return AgentPaneSeedSource { [weak page] in
                let selection = try? await page?.evaluate(AgentPaneSeed.selectionScript, world: .isolated, gesture: .cmux).stringValue
                return AgentPaneSeed(cwd: pageCwd, draft: AgentPaneSeed.browserDraft(title: title, url: url, selection: selection), harness: harness)
            }
        case .agent, .page, .placeholder, .notice, .conversation, nil:
            guard cwd != nil || harness != nil else { return nil }
            return AgentPaneSeedSource(AgentPaneSeed(cwd: cwd, harness: harness))
        }
    }

    /// The harness of the agent chat the person focused last (the selected chat first), by the
    /// rule of ``WorkContextTrail``; nil when no chat of this Mac is a source.
    func inheritedHarness() -> String? {
        let tabs = services.agentTabs
        return services.inheritedWork(besides: selectedTab, in: pane, kinds: [.chat]) { tab in
            guard tabs.lookup(tab.id)?.record.host == tabs.localHost else { return nil }
            return tabs.harness(ofTab: tab.id)
        }
    }
}
