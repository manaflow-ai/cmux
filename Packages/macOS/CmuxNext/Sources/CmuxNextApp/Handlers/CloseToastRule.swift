import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWindowRules

/// Whether closing some tabs earns an undo toast: the rule is Rust's
/// (cmux-window-rules `close::toast`); this reads each closing tab's facts.
@MainActor
struct CloseToastRule {
    enum Decision {
        case show
        case skip
    }

    var titles: TabTitleResolver
    /// A new chat tab's typed text from before it has a session (`AgentUnsentDrafts`).
    var hasUnsentDraft: (TabModel) -> Bool
    var isWorking: (TabModel) -> Bool = { tab in
        if let state = tab.agent?.state, state == .working || state == .blocked { return true }
        return StatusMapping.shared.isWorking(tabs: [tab]) || StatusMapping.shared.needsInput(tab)
    }

    /// Toasts v2 (`CmuxToastCenter.v2`, Leo: "closing a tab or workspace, or archiving a session, shows a
    /// one-line toast with an inline Undo"): every person's close shows its Undo, one idle tab too; the rule is not read.
    var everyCloseShows = false

    init(services: AppServices, everyCloseShows: Bool = false) {
        titles = TabTitleResolver(services: services)
        let agentTabs = services.madeAgentTabs
        hasUnsentDraft = { tab in agentTabs.map { $0.unsentDrafts.hasDraft($0.resolve(tab.id), machine: $0.daemonListing(tab)?.machineID) } ?? false }
        self.everyCloseShows = everyCloseShows
    }

    /// A rule with no app behind it (tests): no unsent drafts, the tabs' own titles.
    init(titles: TabTitleResolver = TabTitleResolver(), hasUnsentDraft: @escaping (TabModel) -> Bool = { _ in false }, everyCloseShows: Bool = false) {
        self.titles = titles
        self.hasUnsentDraft = hasUnsentDraft
        self.everyCloseShows = everyCloseShows
    }

    /// The facts the rule reads of `tab`.
    func facts(_ tab: TabModel) -> WindowRules.ClosingTab {
        let status = tab.agent.map { $0.state == .working || $0.state == .blocked } ?? false
        return WindowRules.ClosingTab(tab, page: titles.page(tab) != nil, newTabPage: titles.isNewTabPage(tab), unsentDraft: hasUnsentDraft(tab),
                                      agentAtWork: status, statusWorking: isWorking(tab))
    }

    /// The rule's answer (cmux-window-rules `close::toast`). An FFI that does not answer shows the
    /// toast: an undo offered too often loses nothing.
    func decide(_ tabs: [TabModel]) -> Decision {
        if everyCloseShows { return .show }
        guard let toast = WindowRules().closeToast(tabs.map(facts)) else { return .show }
        switch toast {
        case .show: return .show
        case .skip: return .skip
        }
    }
}
