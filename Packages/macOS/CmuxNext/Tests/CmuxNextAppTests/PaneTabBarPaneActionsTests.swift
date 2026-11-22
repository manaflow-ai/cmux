import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The pane's actions menu at the tab bar's trailing end (user 2026-11-16: "tabbar right side … is missing now like
/// the one with pane actions"). 821f04425f5a77 (2026-11-13, "get rid of these buttons") took out the Toggle Terminal
/// and Chat pair and the pane's "…" with it; the "…" comes back, alone (the pair stays out): one per pane at its
/// trailing edge, at a tab bar button's size and a tab's corner at every density, with the menu it had (what opens in
/// the pane, the tab's actions without a button, Search Tabs, Show in Tab Bar).
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

    /// The pane's "…" as it shows (found by type, so this reads the bar as drawn).
    static func more(_ view: NSView) -> OverflowButton? {
        view.layoutSubtreeIfNeeded()
        return view.subviews.compactMap { $0 as? OverflowButton }.first { !$0.isHidden }
    }

    /// What the bar shows a person: not views built hidden, nor the hover reveal's pointer probe (it draws nothing).
    static func shownControls(_ view: NSView) -> [NSView] {
        view.layoutSubtreeIfNeeded()
        return view.subviews.filter { !$0.isHidden && !String(describing: type(of: $0)).hasSuffix("HoverRevealProbe") }
    }

    @Test(arguments: [PaneToolbar.Kind.terminal, .newTab, .browser, .other])
    func aTabShowsThePanesActionsAtTheTrailingEdge(kind: PaneToolbar.Kind) throws {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: kind, paneKinds: [kind])
        let more = try #require(Self.more(toolbar.view), "the pane's \"…\" is missing")
        #expect(Self.shownControls(toolbar.view).map { $0 === more } == [true], "only the \"…\" shows with nothing pinned")
        #expect(!toolbar.view.subviews.contains { String(describing: type(of: $0)) == "PaneTerminalChatToggleView" },
                "the Toggle Terminal and Chat pair stays out")
        let side = TitlebarBandButton.side
        #expect(more.frame.width == side && more.frame.height == side, "the \"…\" is \(more.frame.size)")
        #expect(abs(more.frame.maxX - (toolbar.view.bounds.width - PaneToolbarView.trailingGap)) < 0.5, "it sits in the trailing slot")
        #expect(toolbar.view.intrinsicContentSize.width == side + PaneToolbarView.trailingGap, "the bar keeps the \"…\"'s room")
    }

    @Test func itsMenuOffersThePanesActions() throws {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: .terminal, paneKinds: [.terminal])
        let more = try #require(Self.more(toolbar.view))
        let menu = try #require(more.pressMenu?())
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.compactMap(\.submenu).flatMap(all) }
        let ids = Set(all(menu).compactMap { ActionRegistry.menuRun(of: $0)?.id })
        for id: ActionID in ["splitRight", "splitDown", "toggleSplitZoom", "tab.search"] {
            #expect(ids.contains(id), "the \"…\" menu offers \(id.rawValue): \(ids.map(\.rawValue).sorted())")
        }
        #expect(menu.items.contains { $0.title == PaneToolbarStrings.showInTabBar }, "and Show in Tab Bar")
    }

    // A chat selected in the pane shows no "…" but keeps its slot, so the tabs do not move.
    @Test func aChatKeepsTheSlot() {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: .terminal, paneKinds: [.terminal])
        let width = toolbar.view.intrinsicContentSize.width
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal])
        #expect(Self.more(toolbar.view) == nil)
        #expect(toolbar.view.intrinsicContentSize.width == width)
    }

    // A zoomed pane: the "…" lit, Exit Zoom just left of it.
    @Test func aZoomedPaneShowsExitZoomLeftOfALitMore() throws {
        let toolbar = Self.toolbar()
        toolbar.update(target: "t1", kind: .terminal, zoomed: true, paneKinds: [.terminal])
        let more = try #require(Self.more(toolbar.view))
        #expect(more.state == .on, "lit while zoomed")
        #expect(!toolbar.view.zoomButton.isHidden)
        #expect(toolbar.view.zoomButton.frame.maxX <= more.frame.minX + 0.5)
    }

    @Test(arguments: DensityPreset.allCases)
    func theMoreTakesTheTabsSizeAndCornerAtEveryDensity(_ density: DensityPreset) throws {
        try DensityTokens.$scoped.withValue(density.tokens) {
            let toolbar = Self.toolbar()
            toolbar.update(target: "t1", kind: .terminal, paneKinds: [.terminal])
            let more = try #require(Self.more(toolbar.view))
            #expect(more.frame.height == TitlebarBandButton.side, "\(density): \(more.frame.size)")
            #expect(more.plateCornerRadius == Metrics.tabCornerRadius, "\(density): rounds as a tab")
        }
    }
}
