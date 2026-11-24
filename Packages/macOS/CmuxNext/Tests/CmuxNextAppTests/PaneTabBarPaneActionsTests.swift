import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The pane's tab bar has no "⋮" pane actions menu (https://github.com/manaflow-ai/cmux/issues/53356, user 2026-11-23:
/// "gt rid of this, i don't watn to see this… at all", "this menu and the three dots ant the end, no more"). Its
/// menu held New Terminal Tab, New Browser Tab, New Agent Chat, New Cloud Chat, Screen Sharing, New ▸, Split Right,
/// Split Down, Toggle Pane Zoom, Search Tabs… and Show in Tab Bar ▸. No pane kind shows it, the bar keeps no room for
/// it (no gap at the row's end), and those actions stay on their keys, the strip's + and the command palette.
@MainActor @Suite(.serialized)
struct PaneTabBarPaneActionsTests {
    static func toolbar(_ registry: ActionRegistry = Self.registry()) -> PaneToolbar {
        _ = NSApplication.shared
        let toolbar = PaneToolbar(registry: { registry }, paneTarget: ActionTargetRef(kind: .pane, id: "p1"))
        toolbar.view.frame = NSRect(x: 0, y: 0, width: 400, height: 32)
        return toolbar
    }

    static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        for id: ActionID in ["splitRight", "splitDown", "toggleSplitZoom"] { registry.bind(id, invoke: { _ in }) }
        return registry
    }

    /// What the bar shows a person: not views built hidden, nor the hover reveal's pointer probe (it draws nothing).
    static func shownControls(_ view: NSView) -> [NSView] {
        view.layoutSubtreeIfNeeded()
        return view.subviews.filter { !$0.isHidden && !String(describing: type(of: $0)).hasSuffix("HoverRevealProbe") }
    }

    /// Every view under `view`, hidden or not.
    static func tree(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(tree) }

    @Test(arguments: [PaneToolbar.Kind.terminal, .newTab, .browser, .other])
    func noPaneKindShowsAMoreButtonOrKeepsRoomForOne(kind: PaneToolbar.Kind) {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: kind, paneKinds: [kind])
        let views = Self.tree(toolbar.view)
        #expect(!views.contains { $0 is OverflowButton }, "\(kind): the bar builds no ⋮")
        #expect(!views.contains { $0.accessibilityIdentifier() == "cmux.pane.more" }, "\(kind): no cmux.pane.more")
        #expect(Self.shownControls(toolbar.view).isEmpty, "\(kind): nothing shows with nothing pinned")
        #expect(toolbar.view.intrinsicContentSize.width == 0, "\(kind): no room kept at the row's end")
        #expect(!toolbar.view.subviews.contains { String(describing: type(of: $0)) == "PaneTerminalChatToggleView" },
                "the Toggle Terminal and Chat pair stays out")
    }

    /// What the menu listed stays reachable: the splits, zoom and Search Tabs on their keys and in the palette, the
    /// creation rows on the strip's +.
    @Test func theMenusActionsStayOnKeysThePaletteAndThePlus() throws {
        let registry = Self.registry()
        for id: ActionID in ["splitRight", "splitDown", "toggleSplitZoom", "tab.search"] {
            #expect(registry.descriptor(for: id) != nil, "\(id.rawValue) is in the palette")
        }
        for id: ActionID in ["splitRight", "splitDown", "toggleSplitZoom"] {
            #expect(registry.shortcutDisplay(for: id) != nil, "\(id.rawValue) keeps its key")
        }
        let plus = registry.makePaneCreationMenu(target: ActionTargetRef(kind: .pane, id: "p1"))
        let created = Set(plus.items.compactMap { ActionRegistry.menuRun(of: $0)?.id.rawValue })
        #expect(created.contains("newSurface"), "the + opens a terminal: \(created.sorted())")
        #expect(created.contains("palette.newAgentChat"), "the + opens an agent chat: \(created.sorted())")
    }

    /// A pin keeps its slot while a chat (no pins) is selected, so the tabs do not move; with nothing pinned the slot is none.
    @Test func aChatKeepsAPinsSlot() {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: .terminal, pinned: ["splitRight"], paneKinds: [.terminal])
        let width = toolbar.view.intrinsicContentSize.width
        #expect(width > 0)
        toolbar.update(target: "chat", kind: nil, pinned: ["splitRight"], paneKinds: [.terminal])
        #expect(toolbar.view.intrinsicContentSize.width == width)
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal])
        #expect(toolbar.view.intrinsicContentSize.width == 0)
    }

    /// A zoomed pane shows Exit Zoom alone, in the trailing slot, at a tab bar button's size and with no ⋮ beside it.
    @Test(arguments: DensityPreset.allCases)
    func aZoomedPaneShowsExitZoomInTheTrailingSlot(_ density: DensityPreset) {
        DensityTokens.$scoped.withValue(density.tokens) {
            let toolbar = Self.toolbar()
            toolbar.update(target: "t1", kind: .terminal, zoomed: true, paneKinds: [.terminal])
            let shown = Self.shownControls(toolbar.view)
            #expect(shown.count == 1 && shown.first === toolbar.view.zoomButton, "\(density): \(shown)")
            let frame = toolbar.view.zoomButton.frame
            let side = TitlebarBandButton.side
            #expect(frame.width == side && frame.height == side, "\(density): \(frame.size)")
            #expect(abs(frame.maxX - (toolbar.view.bounds.width - PaneToolbarView.trailingGap)) < 0.5, "\(density): trailing slot")
        }
    }
}
