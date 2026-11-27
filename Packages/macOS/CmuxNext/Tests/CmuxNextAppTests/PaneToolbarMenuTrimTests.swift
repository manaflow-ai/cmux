import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

/// What the pane's "…" offered, now that it is gone (user 2026-11-13): the tab bar's right-click holds it. Its own
/// rows and More give what opens in the pane, the splits and zoom; ``PaneToolbar/tabBarMenuRows()`` adds the pins a
/// narrow pane hid, Search Tabs and Show in Tab Bar.
@MainActor
struct PaneToolbarMenuTrimTests {
    /// The tab bar's right-click as the pane builds it, every row of its submenus flattened in.
    static func tabBarMenu(_ registry: ActionRegistry, _ toolbar: PaneToolbar) -> (menu: NSMenu, ids: [ActionID]) {
        let menu = registry.makeTabStripMenu(target: ActionTargetRef(kind: .pane, id: "p1"))
        PaneController.insert(toolbar.tabBarMenuRows(), into: menu)
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(all) }
        return (menu, all(menu).compactMap { ActionRegistry.menuRun(of: $0)?.id })
    }

    @Test(arguments: [CGFloat(12), 240])
    func collapsedPinnedToolsStayInTheTabBarMenu(width: CGFloat) throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let tools: [ActionID] = ["openDiffViewer", "file.open", "agentPane.searchChats"]
        for id in tools { registry.bind(id, invoke: { _ in }) }
        let toolbar = PaneToolbar(registry: { registry })
        toolbar.update(target: "t1", kind: .newTab, pinned: tools.map(\.rawValue))
        toolbar.view.frame = NSRect(x: 0, y: 0, width: width, height: 32)
        toolbar.view.layoutSubtreeIfNeeded()

        let narrow = width == 12 // no room for one button: they all give way
        #expect(toolbar.view.buttons.count == tools.count)
        #expect(toolbar.view.buttons.allSatisfy { $0.isHidden == narrow })
        let ids = toolbar.tabBarMenuRows().joined().compactMap { ActionRegistry.menuRun(of: $0)?.id }
        for id in tools {
            #expect(ids.contains(id) == narrow, "A width-hidden pin stays available in the tab bar's right-click: \(id.rawValue)")
        }
    }

    @Test func theTabBarMenuKeepsCreationSplitsZoomAndSearch() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for id: ActionID in ["splitRight", "splitDown", "toggleSplitZoom"] { registry.bind(id, invoke: { _ in }) }
        let toolbar = PaneToolbar(registry: { registry })
        toolbar.update(target: "t1", kind: .terminal)
        let (menu, ids) = Self.tabBarMenu(registry, toolbar)
        for id: ActionID in ["newSurface", "palette.newAgentChat", "splitRight", "splitDown", "toggleSplitZoom", "tab.search"] {
            #expect(ids.contains(id), "the tab bar's right-click lost \(id.rawValue): \(ids.map(\.rawValue))")
        }
        #expect(menu.items.contains { $0.title == PaneToolbarStrings.showInTabBar && $0.submenu != nil })
        #expect(menu.items.last?.submenu != nil, "More stays the last row")
        for (first, second) in zip(menu.items, menu.items.dropFirst()) {
            #expect(!(first.isSeparatorItem && second.isSeparatorItem))
        }
        #expect(menu.items.first?.isSeparatorItem != true)
    }

    @Test(arguments: [PaneToolbar.Kind.newTab, .terminal, .browser, .other])
    func pinChoicesFollowTheSelectedKind(kind: PaneToolbar.Kind) throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry })
        toolbar.update(target: "t1", kind: kind)
        let pins = try #require(toolbar.tabBarMenuRows().last?.first?.submenu)
        let expected: [ActionID] = switch kind {
        case .newTab: ["splitRight", "splitDown", "openDiffViewer", "file.open", "agentPane.searchChats", "toggleSplitZoom"]
        case .terminal: ["splitRight", "splitDown", "openDiffViewer", "file.open", "toggleSplitZoom"]
        case .browser, .other: ["splitRight", "splitDown", "toggleSplitZoom"]
        }
        #expect(pins.items.map(\.title) == expected.compactMap { registry.descriptor(for: $0)?.title })
    }

    @Test func anInapplicableExistingPinCanStillBeUnpinned() throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry })
        var written: PaneToolbarButtonsSetting?
        toolbar.writePinned = { written = $0 }
        toolbar.update(target: "browser", kind: .browser, pinned: ["file.open"])
        #expect(toolbar.shownPins().isEmpty)
        let pins = try #require(toolbar.tabBarMenuRows().last?.first?.submenu)
        let row = try #require(pins.items.first { $0.title == registry.descriptor(for: "file.open")?.title })
        #expect(row.state == .on)
        _ = row.target?.perform(row.action, with: row)
        #expect(written?.pinned == [])
    }
}
