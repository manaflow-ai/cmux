import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextSettings
import Testing

@MainActor
struct PaneToolbarMenuTrimTests {
    @Test(arguments: [CGFloat(32), 240])
    func collapsedPinnedToolsReturnToOverflow(width: CGFloat) throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        let tools: [ActionID] = ["openDiffViewer", "file.open", "agentPane.searchChats"]
        for id in tools { registry.bind(id, invoke: { _ in }) }
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "t1", kind: .newTab, pinned: tools.map(\.rawValue))
        toolbar.view.frame = NSRect(x: 0, y: 0, width: width, height: 32)
        toolbar.view.layoutSubtreeIfNeeded()

        let narrow = width == 32
        #expect(toolbar.view.buttons.count == tools.count)
        #expect(toolbar.view.buttons.allSatisfy { $0.isHidden == narrow })
        let menu = try #require(toolbar.view.moreMenu?())
        let ids = menu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
        for id in tools {
            #expect(ids.contains(id) == narrow, "A width-hidden pin stays available in overflow: \(id.rawValue)")
        }
    }

    @Test func overflowKeepsCreationSplitsZoomAndSearch() throws {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for id: ActionID in ["splitRight", "splitDown", "toggleSplitZoom", "openDiffViewer", "file.open", "agentPane.searchChats"] {
            registry.bind(id, invoke: { _ in })
        }
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: {
            registry.makeContextMenu(for: .newTab, target: ActionTargetRef(kind: .pane, id: "p1"))
        })
        toolbar.update(target: "t1", kind: .newTab)
        let menu = try #require(toolbar.view.moreMenu?())
        let ids = menu.items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
        #expect(ids == ["newSurface", "openBrowser.chromium", "palette.newAgentChat", "macScreen.open",
                        "agentPane.togglePointerInspector", "splitRight", "splitDown", "toggleSplitZoom", "tab.search"])
        #expect(menu.items.allSatisfy { $0.view == nil }, "standard native menu rows")
        for (first, second) in zip(menu.items, menu.items.dropFirst()) {
            #expect(!(first.isSeparatorItem && second.isSeparatorItem))
        }
        // The plus's menu still offers the profile and New Tab Page commands.
        let plus = registry.makeContextMenu(for: .newTab)
        let plusIDs = plus.items.compactMap { ActionRegistry.menuRun(of: $0)?.id }
        #expect(plusIDs.contains("browserProfile.newTab") && plusIDs.contains("newTab.page"))
    }

    @Test(arguments: [PaneToolbar.Kind.newTab, .terminal, .browser, .other])
    func pinChoicesFollowTheSelectedKind(kind: PaneToolbar.Kind) throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "t1", kind: kind)
        let menu = try #require(toolbar.view.moreMenu?())
        let pins = try #require(menu.items.last?.submenu)
        let expected: [ActionID] = switch kind {
        case .newTab: ["splitRight", "splitDown", "openDiffViewer", "file.open", "agentPane.searchChats", "toggleSplitZoom"]
        case .terminal: ["splitRight", "splitDown", "openDiffViewer", "file.open", "toggleSplitZoom"]
        case .browser, .other: ["splitRight", "splitDown", "toggleSplitZoom"]
        }
        #expect(pins.items.map(\.title) == expected.compactMap { registry.descriptor(for: $0)?.title })
    }

    @Test func anInapplicableExistingPinCanStillBeUnpinned() throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        var written: PaneToolbarButtonsSetting?
        toolbar.writePinned = { written = $0 }
        toolbar.update(target: "browser", kind: .browser, pinned: ["file.open"])
        #expect(toolbar.shownPins().isEmpty)
        let menu = try #require(toolbar.view.moreMenu?())
        let row = try #require(menu.items.last?.submenu?.items.first { $0.title == registry.descriptor(for: "file.open")?.title })
        #expect(row.state == .on)
        _ = row.target?.perform(row.action, with: row)
        #expect(written?.pinned == [])
    }
}
