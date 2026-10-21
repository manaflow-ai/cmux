import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
import CmuxNextDesign
@testable import CmuxNextHome
import CmuxNextSidebar
import Testing

/// Leo 2026-10-20: the Chief's pane gets a top-right area like a workspace's (status, subagents,
/// actions), in its pane's tab row like a chat's header tools (`PaneTabRowSharing`). The docked
/// Home's Messages view puts its tools at the row's trailing end, left of the pane's own toolbar,
/// sits under the row only while they are in it, and Channels has none. The Chief's tools show its
/// status, its subagents and its actions.
@MainActor @Suite struct HomeDockTabRowToolsTests {
    final class Dock: HomeDockSwitchView {
        override func makeContent(for mode: HomeDockMode) -> NSView? { NSView() }
    }

    final class Tools: NSView {
        override var intrinsicContentSize: NSSize { NSSize(width: 60, height: 20) }
    }

    static func dock() -> (Dock, Tools) {
        let dock = Dock(mode: .messages)
        let tools = Tools()
        dock.rowTools = [.messages: tools]
        dock.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        dock.layoutSubtreeIfNeeded()
        return (dock, tools)
    }

    @Test func messagesReportsItsToolsAndDrawsThemInTheOfferedRow() {
        let (dock, tools) = Self.dock()
        var changes = 0
        dock.onTabRowToolsChange = { changes += 1 }
        let width = 60 + Metrics.space2
        #expect(dock.tabRowToolsWidth == width)
        #expect(dock.tabRowToolsNeed == width)
        #expect(dock.fitsTabRow(room: width * 2))
        #expect(!dock.fitsTabRow(room: width))
        #expect(tools.isHidden) // not offered the row yet
        dock.setTabRow(height: 28, trailingInset: 40)
        dock.layoutSubtreeIfNeeded()
        #expect(!tools.isHidden)
        #expect(tools.frame == NSRect(x: 400 - 40 - 60, y: 300 - 28, width: 60, height: 28)) // the top: the dock is not flipped
        #expect(dock.subviews.first?.frame == NSRect(x: 0, y: 0, width: 400, height: 272))
        dock.setTabRow(height: 0, trailingInset: 0)
        dock.layoutSubtreeIfNeeded()
        #expect(tools.isHidden)
        #expect(dock.subviews.first?.frame == dock.bounds)
        #expect(changes == 0) // the width did not change
    }

    @Test func channelsHasNoTools() {
        let dock = Dock(mode: .channels)
        let tools = Tools()
        dock.rowTools = [.messages: tools]
        dock.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        dock.setTabRow(height: 28, trailingInset: 0)
        dock.layoutSubtreeIfNeeded()
        #expect(dock.tabRowToolsWidth == nil)
        #expect(dock.tabRowToolsNeed == nil)
        #expect(tools.isHidden)
        #expect(dock.subviews.first?.frame == dock.bounds)
    }

    /// The Chief's tools: its status on the mark, Subagents only with a subagent, and Chief
    /// Actions from the catalog in order.
    @Test func theChiefsToolsShowItsStatusSubagentsAndActions() {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let tools = ChiefPaneTools(chief: ChiefSidebar(lanes: AgentLaneStore()), registry: registry)
        tools.show(.init(), subagents: 0)
        #expect(tools.indicator.state == .idle)
        #expect(!tools.subagentsButton.isEnabled)
        tools.show(.init(activity: .waiting, badge: 1), subagents: 2)
        #expect(tools.indicator.state == .waiting)
        #expect(tools.subagentsButton.isEnabled)
        #expect(tools.subagentsMenu().items.isEmpty) // this store has no lanes
        let ids = tools.actionsMenu()?.items.compactMap { $0.identifier?.rawValue }
        #expect(ids == ChiefPaneTools.actions.map { "cmux.action.\($0.rawValue)" })
        #expect(tools.intrinsicContentSize.width > 0)
    }

    /// Each Subagents row runs Open Chief Subagent on its row's sidebar item through the registry (the one
    /// path the palette, shortcuts and `cmux action run` share), titled and described like its
    /// sidebar row; no row runs a selector of its own (scripts/cmux-next/check-menu-actions.py).
    @Test func eachSubagentRowOpensItsSessionThroughTheRegisteredAction() {
        let lanes = AgentLaneStore()
        for (name, state) in [("optchat-sub-6b68ac4a-a2", AgentActivityLane.State.idle), ("optchat-sub-6b68ac4a-a3", .working)] {
            lanes.lanes["id-" + name] = AgentActivityLane(id: "id-" + name, name: name, title: name, peer: nil, parent: "optchat-chief:6b68ac4a",
                                                          state: state, since: nil, error: nil, harness: "claude")
        }
        let chief = ChiefSidebar(lanes: lanes)
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let tools = ChiefPaneTools(chief: chief, registry: registry)
        let rows = chief.allSubagents(), items = tools.subagentsMenu().items
        #expect(rows.count == 2)
        #expect(items.map(\.title) == rows.map(\.info.title))
        #expect(items.map(\.toolTip) == rows.map(\.info.activity.shortLabel))
        let runs = items.compactMap(ActionRegistry.menuRun(of:))
        #expect(runs.map(\.id) == Array(repeating: ActionID("chief.openSubagent"), count: rows.count))
        // The target is the row's sidebar item, the same id a click on its sidebar row activates.
        #expect(runs.map(\.target) == rows.map { Optional(ActionTargetRef(kind: .sidebarItem, id: $0.item.id.rawValue)) })
        #expect(runs.compactMap { $0.target.map { SidebarTransientItem.chiefSubagentSession(LayoutItemID($0.id)) } }
            == ["id-optchat-sub-6b68ac4a-a2", "id-optchat-sub-6b68ac4a-a3"])
        #expect(runs.allSatisfy { $0.arguments.isEmpty })
    }

    /// Chief Actions is the app's one more button (⋮, OverflowButton): VoiceOver's press opens the
    /// same menu a pointer press does.
    @Test func chiefActionsIsTheOverflowButton() {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let tools = ChiefPaneTools(chief: ChiefSidebar(lanes: AgentLaneStore()), registry: registry)
        var shown: NSMenu?
        tools.actionsButton.presentMenu = { menu, _ in shown = menu }
        #expect(tools.actionsButton.accessibilityPerformPress())
        #expect(shown?.items.count == ChiefPaneTools.actions.count)
        #expect(tools.actionsButton.accessibilityLabel() == tools.actionsButton.label)
    }
}
