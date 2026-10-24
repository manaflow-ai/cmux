import AppKit
@testable import CmuxNextAgentPane
import CmuxNextActions
import CmuxNextDesign
import Testing
@testable import CmuxNextApp

/// Inspect Element in an agent page's context menu (the Labs pointer inspector,
/// `agent.pointerInspector`) reaches the app's inspector through the tab store's hook, a direct
/// call from the page that asks: the menu once posted the app-wide `cmux.next.inspect-ui-element`
/// broadcast instead, which no one heard until the inspector had been made by another path.
@MainActor @Suite(.serialized)
struct AgentPaneInspectElementTests {
    /// How often the app's inspector was asked to start.
    private final class Inspections {
        var count = 0
    }

    /// The tabs' page: a loopback dev server origin (Debug), so views are made without the bundle.
    private static func agentTabs() -> AgentTabStore {
        let environment = [AgentPaneSource.devURLVariable: "http://127.0.0.1:9"]
        let tabs = AgentTabStore(build: nil, registry: ActionRegistry.standard(), environment: environment, showcase: true)
        tabs.localHost = "install:this-mac"
        return tabs
    }

    /// Debug Settings with the pointer inspector `on` (nil: back to its default).
    private static func pointerInspector(_ on: Bool?) {
        let store = TunableStore.shared
        store.activate(file: nil)
        store.register(AgentPaneTunables.all)
        store.set(AgentPaneTunables.pointerInspector.key, on.map { .bool($0) })
    }

    /// The pane's right-click menu on empty space, as WebKit or the page host asks the pane for it.
    private static func contextMenu(of view: AgentPaneView) -> NSMenu {
        let menu = NSMenu()
        view.editContextMenu(menu)
        return menu
    }

    @Test func inspectElementInAPagesMenuStartsTheAppsInspector() throws {
        Self.pointerInspector(true)
        defer { Self.pointerInspector(nil) }
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        let inspections = Inspections()
        tabs.inspectUIElement = { _, _ in inspections.count += 1 }
        let view = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))

        let menu = Self.contextMenu(of: view)
        let item = try #require(menu.items.first { $0.title == "Inspect Element" }, "the page's menu offers no Inspect Element")
        menu.performActionForItem(at: menu.index(of: item))
        #expect(inspections.count == 1, "Inspect Element in the page's menu did not reach the app's inspector")
    }

    /// Through the app's own wiring (`AgentTabStore.wired(to:)`), not a test hook: Inspect Element
    /// in a page's menu starts the app's inspector, on its first use too (nothing made the
    /// inspector before the menu action).
    @Test func inspectElementThroughTheAppsWiringStartsItsInspector() throws {
        Self.pointerInspector(true)
        defer { Self.pointerInspector(nil) }
        _ = NSApplication.shared
        let agentPaneEnvironment = [
            AgentPaneSource.devURLVariable: "http://127.0.0.1:9",
            "CMUX_NEXT_AGENT_PANE_MOCK": "1",
        ]
        let services = AppServices(environment: AppEnvironment.current([:]), agentPaneEnvironment: agentPaneEnvironment)
        try #require(services.agentTabs.canHostChat, "no agent page source")
        let view = try #require(services.agentTabs.makeSpare(AgentPaneNewTab(kind: .agent)))

        let menu = Self.contextMenu(of: view)
        let item = try #require(menu.items.first { $0.title == "Inspect Element" }, "the page's menu offers no Inspect Element")
        menu.performActionForItem(at: menu.index(of: item))
        let picking = services.uiInspector.isPicking
        services.uiInspector.toggle()
        #expect(picking, "Inspect Element in the page's menu did not start the app's inspector")
    }

    @Test func withThePointerInspectorOffThePagesMenuOffersNoInspectElement() throws {
        Self.pointerInspector(false)
        defer { Self.pointerInspector(nil) }
        let tabs = Self.agentTabs()
        try #require(tabs.canHostChat, "no agent page source")
        let inspections = Inspections()
        tabs.inspectUIElement = { _, _ in inspections.count += 1 }
        let view = try #require(tabs.makeSpare(AgentPaneNewTab(kind: .agent)))

        #expect(!Self.contextMenu(of: view).items.contains { $0.title == "Inspect Element" })
        #expect(inspections.count == 0)
    }
}
