import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// The vertical tabs rows of the tab bar's menu (Leo 2026-10-20: "a per-workspace Vertical tabs option,
/// off by default, and a Use vertical tabs for all workspaces control"): Use Vertical Tabs for All
/// Workspaces and Auto-Expand Tabs on Hover are checked toggles of their settings, Collapse Tabs reads
/// Expand Tabs while the lists are collapsed, and the rows that act on a vertical list leave a strip's menu.
@MainActor @Suite(.serialized)
struct VerticalTabsMenuTests {
    struct Fixture {
        let services: AppServices
        let design: DesignSettings
        let store: WorkspaceVerticalTabs
        var registry: ActionRegistry { services.registry }
    }

    /// The app's actions, with the vertical tabs ones on a design and a store of their own.
    static func fixture() throws -> Fixture {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        var context = AppActionContext(services: services)
        let design = DesignSettings()
        context.design = design
        let store = WorkspaceVerticalTabs(defaults: try #require(UserDefaults(suiteName: "VerticalTabsMenuTests.\(UUID().uuidString)")))
        VerticalTabsHandlers.bind(into: services.registry, context: context, store: store)
        return Fixture(services: services, design: design, store: store)
    }

    @Test func useVerticalTabsForAllWorkspacesIsACheckedToggleThatClearsEachWorkspacesChoice() throws {
        let f = try Self.fixture()
        f.store.set(false, for: "ws_off", allWorkspaces: true)
        #expect(f.store.choice(for: "ws_off") == false)
        let action = try #require(f.registry.action(for: VerticalTabsHandlers.allWorkspaces))
        #expect(action.targetState?(ActionInvocation()) == false)
        #expect(f.registry.perform(VerticalTabsHandlers.allWorkspaces))
        #expect(f.design.verticalTabs)
        #expect(f.registry.action(for: VerticalTabsHandlers.allWorkspaces)?.targetState?(ActionInvocation()) == true)
        #expect(f.registry.action(for: VerticalTabsHandlers.allWorkspaces)?.paletteState?() == true)
        // Turned on for all, every workspace shows vertical tabs: a workspace's own Off goes.
        #expect(f.store.choice(for: "ws_off") == nil)
        #expect(f.store.isVertical("ws_off", allWorkspaces: f.design.verticalTabs))
        #expect(f.registry.perform(VerticalTabsHandlers.allWorkspaces))
        #expect(!f.design.verticalTabs)
    }

    @Test func autoExpandOnHoverIsACheckedToggleOfItsSetting() throws {
        let f = try Self.fixture()
        #expect(f.design.verticalTabsExpandOnHover, "on by default")
        #expect(f.registry.action(for: VerticalTabsHandlers.expandOnHover)?.targetState?(ActionInvocation()) == true)
        #expect(f.registry.perform(VerticalTabsHandlers.expandOnHover))
        #expect(!f.design.verticalTabsExpandOnHover)
        #expect(f.registry.action(for: VerticalTabsHandlers.expandOnHover)?.targetState?(ActionInvocation()) == false)
    }

    @Test func collapseTabsReadsExpandTabsWhileCollapsed() throws {
        let f = try Self.fixture()
        #expect(f.registry.action(for: VerticalTabsHandlers.collapse)?.targetTitle?(ActionInvocation()) == nil, "the catalog's Collapse Tabs")
        #expect(f.registry.perform(VerticalTabsHandlers.collapse))
        #expect(f.store.isCollapsed)
        #expect(f.registry.action(for: VerticalTabsHandlers.collapse)?.targetTitle?(ActionInvocation()) == "Expand Tabs")
        #expect(f.registry.action(for: VerticalTabsHandlers.collapse)?.paletteTitle?() == "Expand Tabs")
        #expect(f.registry.perform(VerticalTabsHandlers.collapse))
        #expect(!f.store.isCollapsed)
    }

    /// A pane with no vertical list (here: none shown) offers no Collapse Tabs or Auto-Expand Tabs on Hover;
    /// Turn On Vertical Tabs and Use Vertical Tabs for All Workspaces stay. The pane's own rows stay in More.
    @Test func aStripsMenuLeavesOutTheRowsOfAVerticalList() throws {
        let f = try Self.fixture()
        let menu = TabStripMenu.make(target: ActionTargetRef(kind: .pane, id: "p_none"), registry: f.registry)
        let ids = menu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue }
        #expect(ids.contains(VerticalTabsHandlers.toggle.rawValue))
        #expect(ids.contains(VerticalTabsHandlers.allWorkspaces.rawValue))
        #expect(!ids.contains(VerticalTabsHandlers.collapse.rawValue))
        #expect(!ids.contains(VerticalTabsHandlers.expandOnHover.rawValue))
        let more = try #require(menu.items.last?.submenu, "the strip's earlier rows stay in More")
        func all(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { (ActionRegistry.menuRun(of: $0).map { [$0.id.rawValue] } ?? []) + ($0.submenu.map(all) ?? []) }
        }
        #expect(all(more).contains("splitRight"))
    }
}
