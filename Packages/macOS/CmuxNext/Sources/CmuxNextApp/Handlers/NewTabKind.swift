import CmuxNextActions
import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextSettings
import CmuxNextWindowRules

/// What Cmd-T opens in a pane: the rule is Rust's (cmux-window-rules `tabs::new_tab_kind`).
typealias NewTabKind = WindowRules.NewTabKind

extension WindowRules.NewTabKind {
    /// The action that opens this kind on its own, whose title New <Kind> Tab takes in a tab's menu.
    var newActionID: ActionID {
        switch self {
        case .terminal: "newSurface"
        case .browser: "openBrowser"
        case .agent: "palette.newAgentChat"
        case .page: "newTab.page"
        }
    }

    /// The facts of the tab a new tab opens next to: `agent` counts only where the caller counts it.
    static func facts(_ tab: TabModel?, id: String?, agent: Bool, newTabPage: Bool, user: Bool = false, followsSetting: Bool = false,
                      canHostAgent: Bool = false) -> WindowRules.NewTabFacts {
        let kind: String? = switch tab?.kind {
        case .pty?: "pty"
        case .browser?: "browser"
        case nil: nil
        default: "other"
        }
        return WindowRules.NewTabFacts(selectedKind: kind, engine: tab?.browserEngine, localBrowser: id?.hasPrefix(LocalBrowserTab.prefix) == true,
                                       agent: agent, newTabPage: newTabPage, user: user, followsSetting: followsSetting, canHostAgent: canHostAgent)
    }

    /// The kind New <Kind> Tab opens next to tab `id`, as the user sees it:
    /// agent tabs and New Tab pages count (`newTabOfPaneKind`). A terminal when the FFI does not answer.
    @MainActor static func of(_ id: String, tab: TabModel?, services: AppServices) -> NewTabKind {
        let agent = services.agentTabs.isAgentTab(id)
        let facts = facts(tab, id: id, agent: agent, newTabPage: agent && services.agentTabs.isNewTabPage(id))
        return WindowRules().newTabKind(facts)?.sameKind ?? .terminal
    }
}
