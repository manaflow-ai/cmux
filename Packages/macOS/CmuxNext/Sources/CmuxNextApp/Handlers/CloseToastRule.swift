import CmuxNextBridge
import CmuxNextBridgeUI
import CmuxNextBrowser
import CmuxNextDaemon

/// Whether closing some tabs earns an undo toast (Lawrence 2026-10-12: "this
/// toast shows up too often"). Cmd-Shift-T reopens every close, so the toast
/// is only for a close that is costly to get back:
/// - several real tabs in one gesture (a tab group, close others, a pane);
/// - an agent at work in a closing tab (an acpmux turn or a terminal agent
///   working or waiting on the user), or a new chat's unsent text;
/// - a terminal running a program (asked of the daemon, `pendingTerminals`).
/// Never for one idle tab, and never for tabs that reopen with no loss:
/// internal pages (Settings, History, What's New, Debug Settings, an app's
/// page), a New Tab or blank browser page, a dead tab.
@MainActor
struct CloseToastRule {
    enum Decision {
        case show
        case skip
        /// Shows only if one of these live terminals runs a program.
        case askTerminals([TabModel])
    }

    var titles: TabTitleResolver
    /// A new chat tab's typed text from before it has a session (`AgentUnsentDrafts`).
    var hasUnsentDraft: (TabModel) -> Bool
    var isWorking: (TabModel) -> Bool = { tab in
        if let state = tab.agent?.state, state == .working || state == .blocked { return true }
        return StatusMapping.shared.isWorking(tabs: [tab]) || StatusMapping.shared.needsInput(tab)
    }

    init(services: AppServices) {
        titles = TabTitleResolver(services: services)
        let agentTabs = services.madeAgentTabs
        hasUnsentDraft = { tab in agentTabs.map { $0.unsentDrafts.hasDraft($0.resolve(tab.id)) } ?? false }
    }

    /// A tab that reopens with nothing lost: a page, a New Tab or blank page, a dead tab.
    /// A new chat with typed text is not (its tab is still a New Tab page).
    func reopensFree(_ tab: TabModel) -> Bool {
        if hasUnsentDraft(tab) { return false }
        if tab.dead || titles.page(tab) != nil || titles.isNewTabPage(tab) { return true }
        guard tab.kind == .browser else { return false }
        let url = tab.url ?? ""
        return url.isEmpty || url == "about:blank" || BrowserNewTabPage.isNewTabPage(url)
    }

    func decide(_ tabs: [TabModel]) -> Decision {
        let real = tabs.filter { !reopensFree($0) }
        if real.count >= 2 { return .show }
        if real.contains(where: { isWorking($0) || hasUnsentDraft($0) }) { return .show }
        let terminals = real.filter { $0.kind == .pty }
        return terminals.isEmpty ? .skip : .askTerminals(terminals)
    }
}
