import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The tab bar's trailing end. Leo (2026-10-19) had its controls show muted at rest; Lawrence
/// (2026-10-20) wants the plus and "…" hidden until the pointer is over the tab bar, and the Search Tabs
/// chevron gone from the bar ("i dont like the down arrow"), its action kept in "…"'s menu. The
/// controls keep their room, so nothing moves when they appear; "…" slides right into its slot as it
/// fades in (no slide under Reduce Motion).
@MainActor @Suite(.serialized) struct TabBarRestingControlsTests {
    private static func strip() -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: (0..<4).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let strip = TabStripView(model: model)
        strip.dragsWindowFromEmptySpace = false
        strip.frame = NSRect(x: 0, y: 0, width: 900, height: TabStripView.preferredHeight)
        window.contentView = strip
        strip.layoutSubtreeIfNeeded()
        return (strip, window)
    }

    @Test func theStripsPlusHidesAtRestAndShowsOnHover() throws {
        DesignSettings.shared.plusButton = .hover
        let (strip, window) = Self.strip()
        defer { window.orderOut(nil) }
        let reveal = try #require(HoverReveal.owner(of: strip.newTabButton))
        #expect(TabTunables.restingControlOpacity.value == 0, "tab bar controls hide at rest by default")
        #expect(!reveal.isRevealed)
        #expect(strip.newTabButton.alphaValue == 0, "plus at rest: \(strip.newTabButton.alphaValue)")
        #expect(!strip.newTabButton.isHidden, "hidden by alpha only: it keeps its room and its accessibility")
        reveal.setPointerInside(true)
        #expect(reveal.isRevealed)
        reveal.setPointerInside(false)
        #expect(reveal.restAlpha == 0)
    }

    @Test func aRevealsRestAlphaIsWhatItsViewsShowAtRest() {
        let region = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        let reveal = HoverReveal(region: region, tracksPointer: false)
        let view = NSView()
        reveal.add(view)
        #expect(view.alphaValue == 0, "the default stays hidden at rest (title bar buttons, sidebar footer)")
        reveal.restAlpha = 0.4
        #expect(abs(view.alphaValue - 0.4) < 0.01)
        let other = NSView()
        reveal.add(other)
        #expect(abs(other.alphaValue - 0.4) < 0.01)
        reveal.isEnabled = false
        #expect(reveal.isRevealed)
    }

    @Test func thePanesMoreHidesAtRestAndStaysForItsMenuAndFocus() {
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        let more = toolbar.view.moreButton
        #expect(!more.isHidden)
        #expect(more.alphaValue == 0, "\"…\" at rest: \(more.alphaValue)")
        // An open menu holds the reveal (the pointer leaves the bar for the menu).
        let hold = toolbar.view.reveal.hold()
        #expect(toolbar.view.reveal.isRevealed)
        hold.release()
        #expect(!toolbar.view.reveal.isRevealed)
    }

    /// The chevron (Search Tabs) is gone from the bar; "…"'s menu runs it with no tab target (a tab target
    /// only reveals that tab). The bar keeps room for "…" alone, so the tabs get the chevron's width.
    @Test func searchTabsMovesFromTheBarIntoMoresMenu() throws {
        let registry = ActionRegistry.standard()
        var invocations: [ActionInvocation] = []
        registry.bind("tab.search", invoke: { invocations.append($0) })
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        #expect(!toolbar.view.items.map(\.id).contains("tab.search"), "no chevron in the bar")
        #expect(toolbar.view.buttons.isEmpty)
        #expect(toolbar.view.reservedCount == 1, "\"…\" only")
        let menu = try #require(toolbar.view.moreMenu?())
        let row = try #require(menu.items.first { ActionRegistry.menuRun(of: $0)?.id == "tab.search" }, "Search Tabs in \"…\"")
        #expect(ActionRegistry.menuRun(of: row)?.target == nil)
        _ = row.target?.perform(row.action, with: row)
        #expect(invocations.count == 1)
        #expect(invocations.first?.target == nil)
        // A chat selected in a pane with terminals keeps "…"'s room; a pane of chats only has no bar.
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal])
        #expect(toolbar.view.items.isEmpty)
        #expect(toolbar.view.reservedCount == 1)
        toolbar.update(target: "chat", kind: nil)
        #expect(toolbar.view.reservedCount == 0)
    }

    @Test func showInTabBarOnlyOffersControlsForTheSelectedKind() throws {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "browser", kind: .browser)
        let menu = try #require(toolbar.view.moreMenu?())
        let show = try #require(menu.items.first { $0.title == PaneToolbarStrings.showInTabBar })
        #expect(Set(show.submenu?.items.map(\.title) ?? []) == Set(["Split Right", "Split Down", "Toggle Pane Zoom"]))
        toolbar.update(target: "browser", kind: .browser, pinned: ["file.open"])
        let pinnedMenu = try #require(toolbar.view.moreMenu?())
        let pinnedShow = try #require(pinnedMenu.items.first { $0.title == PaneToolbarStrings.showInTabBar })
        #expect(pinnedShow.submenu?.items.map(\.title).contains("Open File") == true,
                "an incompatible existing pin stays available so it can be removed")
    }

    /// "…" slides right into its trailing slot as it fades in; Reduce Motion keeps it in place (fade only).
    @Test func moreSlidesRightIntoItsSlotOnReveal() {
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        let view = toolbar.view
        view.frame = NSRect(x: 0, y: 0, width: view.intrinsicContentSize.width, height: 30)
        view.layoutSubtreeIfNeeded()
        let shown = view.moreFrame(revealed: true), resting = view.moreFrame(revealed: false)
        #expect(shown.maxX <= view.bounds.width, "\"…\" sits in the trailing slot")
        #expect(resting.minX < shown.minX, "at rest \"…\" waits left of its slot, so revealing moves it right")
        #expect(view.moreButton.frame == resting)
        Motion.reduceMotionOverride = true
        #expect(view.moreFrame(revealed: false) == view.moreFrame(revealed: true), "Reduce Motion: no slide")
    }
}
