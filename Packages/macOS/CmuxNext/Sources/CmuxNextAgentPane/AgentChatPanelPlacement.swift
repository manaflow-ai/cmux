/// Placement choices for panels opened beside an agent chat.
@MainActor
package struct AgentChatPanelPlacement {
    package init() {}

    /// Terminal and Browser open as tabs in an existing side pane when enabled.
    private func panelTabs(_ id: String) -> Bool {
        AgentPaneTunables.panelTabs.value && (id == "splitRight" || id == "splitBrowserRight")
    }

    /// Uses an existing panel first, otherwise the first suitable pane beside the chat.
    package func target<Tab>(_ id: String, anchor: Tab?, tabs: [Tab], beside: (Tab) -> Bool) -> Tab? {
        anchor ?? (panelTabs(id) ? tabs.first(where: beside) : nil)
    }

    /// A new side column starts with tiles of the surfaces it can hold.
    package func configure(_ page: inout AgentPaneNewTab, split: Bool) {
        if split, AgentPaneTunables.sideColumn.value { page.surfaces = true }
    }

    package func open(_ id: String, on target: String?, terminal: () -> Void, browser: () -> Void) -> Bool {
        guard target != nil, panelTabs(id) else { return false }
        if id == "splitRight" { terminal() } else { browser() }
        return true
    }

    /// A shared chat pane may dock too; tabbed side panels keep the chat in place.
    package func dock<Controller>(_ controller: Controller?, resolve: (Controller, Bool) -> Bool) -> Controller? {
        AgentPaneTunables.panelTabs.value ? nil
            : controller.flatMap { resolve($0, AgentPaneTunables.dockBesideTabs.value) ? $0 : nil }
    }

    /// Prefers the caller when several chats share the pane being docked.
    package func chat<Tab>(in tabs: [Tab]?, caller: String?, id: (Tab) -> String, isChat: (Tab) -> Bool) -> Tab? {
        tabs?.first { id($0) == caller && isChat($0) } ?? tabs?.first(where: isChat)
    }
}
