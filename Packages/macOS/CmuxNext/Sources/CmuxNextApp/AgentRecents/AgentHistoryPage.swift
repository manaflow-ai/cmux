import CmuxNextAgentPane
import Foundation

/// Agent history (cx-zlnl; Show Agent History on the palette and Window menu, cx-qno.24): every
/// coding agent chat on this device, newest first. It is the New Tab page's All chats list
/// (cx-n0i9) on a page of its own: the same chat index (`chats.page`) and Open Chat path;
/// Bring into Active Sessions opens each picked chat in a new workspace of the current space.
enum AgentHistoryPage {
    /// The History page in `pane`: the one it shows already stays, else a new tab beside it.
    static func open(in pane: PaneController) {
        let services = pane.services
        if let key = pane.currentTabKey, title(key, services) != nil {
            services.windowController(showing: pane)?.focus.send(.focusPane(pane.paneKey, source: .intent))
            return
        }
        var page = NewTabPage.page(services, selected: pane.selectedTab, pane: pane)
        let cwd = page.cwd
        page.history = true
        page.focusesField = false
        let handler = NewTabPage.handler(services, cwd: cwd) { _, _ in }
        pane.openAgentTab(seed: nil, newTab: (page, handler))
    }

    /// The strip title of tab `key` when it shows agent history, else nil.
    static func title(_ key: String, _ services: AppServices) -> String? {
        services.agentTabs.newTabPage(key)?.page.history == true ? Strings.agentHistory : nil
    }
}

extension Strings {
    static var agentHistory: String { String(localized: "tab.agentHistory", defaultValue: "History", bundle: .module) }
}
