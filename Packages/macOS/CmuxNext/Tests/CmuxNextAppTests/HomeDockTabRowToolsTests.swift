import AppKit
import CmuxNextActions
import CmuxNextAgentActivity
@testable import CmuxNextAgentLanes
@testable import CmuxNextApp
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

    @MainActor final class Notices {
        var shown: [String] = []
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

    /// The Chief's tools: only its status on the mark; Chief Actions from the catalog in order, then
    /// Subagents (enabled only with a subagent), as rows of the pane's one ⋮ (Lawrence 2026-10-22).
    @Test func theChiefsToolsShowItsStatusAndPutActionsInThePanesMenu() {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let tools = ChiefPaneTools(chief: ChiefSidebar(lanes: AgentLaneStore()), registry: registry)
        tools.show(.init(), subagents: 0)
        #expect(tools.indicator.state == .idle)
        #expect(!tools.hasSubagents)
        tools.show(.init(activity: .waiting, badge: 1), subagents: 2)
        #expect(tools.indicator.state == .waiting)
        #expect(tools.hasSubagents)
        #expect(tools.subagentsMenu().items.isEmpty) // this store has no lanes
        let rows = tools.paneMoreMenuItems()
        let ids = rows.compactMap { $0.identifier?.rawValue }
        #expect(ids == ChiefPaneTools.actions.map { "cmux.action.\($0.rawValue)" } + ["cmux.chief.paneTools.subagents"])
        #expect(rows.allSatisfy { $0.menu == nil }, "fresh rows, free to go into the pane's menu")
        let subagents = rows.last
        #expect(subagents?.submenu != nil)
        #expect(subagents?.isEnabled == false) // no lanes, nothing to open
        #expect(tools.intrinsicContentSize.width == TitlebarBandButton.side)
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
        // An untitled subagent's sidebar row stays icon-led under the Chief header; the menu, which has no
        // such header, names it Subagent (Leo 2026-10-29).
        #expect(rows.map(\.info.title) == ["", ""])
        #expect(items.map(\.title) == rows.map { $0.info.title.isEmpty ? ChiefToolStrings.subagent : $0.info.title })
        #expect(items.map(\.toolTip) == rows.map(\.info.activity.shortLabel))
        let runs = items.compactMap(ActionRegistry.menuRun(of:))
        #expect(runs.map(\.id) == Array(repeating: ActionID("chief.openSubagent"), count: rows.count))
        // The target is the row's sidebar item, the same id a click on its sidebar row activates.
        #expect(runs.map(\.target) == rows.map { Optional(ActionTargetRef(kind: .sidebarItem, id: $0.item.id.rawValue)) })
        #expect(runs.compactMap { $0.target.map { SidebarTransientItem.chiefSubagentSession(LayoutItemID($0.id)) } }
            == ["id-optchat-sub-6b68ac4a-a2", "id-optchat-sub-6b68ac4a-a3"])
        #expect(runs.allSatisfy { $0.arguments.isEmpty })
    }

    /// Open Chief Subagent run with no subagent row (its shortcut, `cmux action run` without
    /// `--target`) says why in the refusal notice a keyboard run shows, and the caller gets the
    /// reason, instead of doing nothing.
    @Test func openSubagentWithNoSubagentRefusesVisibly() {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        let registry = services.registry
        let notices = Notices()
        let shows = registry.refusalObserver
        registry.refusalObserver = { reason, quiet in
            if !quiet { notices.shown.append(reason) }
            shows?(reason, quiet)
        }
        defer { registry.refusalObserver = shows }
        _ = registry.perform(ChiefSidebar.openSubagentAction, invocation: ActionInvocation(origin: .user))
        #expect(notices.shown.count == 1)
        #expect(notices.shown.allSatisfy { !$0.isEmpty })
        let refusal = registry.capturingRefusal {
            _ = registry.perform(ChiefSidebar.openSubagentAction, invocation: ActionInvocation(origin: .user))
        }
        #expect(refusal != nil)
        #expect(refusal == notices.shown.first)
    }

    /// One ⋮, not two (Lawrence 2026-10-22: "like tf are these buttons for"): the Chief's tools draw
    /// no button of their own, only the status mark; their rows sit at the top of the pane's more menu,
    /// above a separator and the pane's own rows.
    @Test func theChiefsToolsAreNoButtonsAndLeadThePanesOneMoreMenu() throws {
        let registry = ActionRegistry(catalog: ActionCatalog.all, aliases: ActionCatalog.legacyAliases)
        let tools = ChiefPaneTools(chief: ChiefSidebar(lanes: AgentLaneStore()), registry: registry)
        #expect(tools.subviews.count == 1)
        #expect(tools.subviews.first === tools.indicator)
        #expect(!tools.subviews.contains { $0 is NSButton })
        let dock = Dock(mode: .messages)
        dock.rowTools = [.messages: tools]
        let chiefRows = ChiefPaneTools.actions.count + 2 // the actions, a separator, Subagents
        #expect(dock.paneMoreMenuItems().count == chiefRows)
        let channels = Dock(mode: .channels)
        channels.rowTools = [.messages: ChiefPaneTools(chief: ChiefSidebar(lanes: AgentLaneStore()), registry: registry)]
        #expect(channels.paneMoreMenuItems().isEmpty)
        let standard = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { standard }, newTabMenu: { nil }, contentMenu: { dock.paneMoreMenuItems() })
        toolbar.update(target: "tab0", kind: .other)
        let menu = try #require(toolbar.view.moreMenu?())
        let ids = menu.items.prefix(ChiefPaneTools.actions.count).compactMap { $0.identifier?.rawValue }
        #expect(ids == ChiefPaneTools.actions.map { "cmux.action.\($0.rawValue)" })
        #expect(menu.items[chiefRows].isSeparatorItem, "the Chief's rows end above the pane's own")
        #expect(menu.items.count > chiefRows + 1)
    }

    /// The Home header's second row of toggles (Memory, Right Sidebar) is off by default: the
    /// header keeps one row (Memory is in Chief Actions; the right sidebar is View > Toggle Right Sidebar).
    @Test func theHomeHeaderHasNoSecondRowByDefault() {
        #expect(HomeTunables.headerPanelToggles.defaultValue == false)
    }
}
