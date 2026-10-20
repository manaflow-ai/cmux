import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import Testing

/// The tab bar's trailing end (Leo 2026-10-19): the room kept for its controls read as an empty gap,
/// because the strip's plus and the pane's "…" were invisible until the pointer reached the strip.
/// They keep their room (an overlay would cover the last tabs and a reveal that pushes them moves the
/// tabs under the pointer), but now show at rest in a muted tone and brighten on hover. The bar also
/// gets Chrome's tab search button, Search Tabs (Cmd-Shift-A), before "…".
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

    @Test func theStripsPlusShowsMutedAtRestAndBrightensOnHover() throws {
        DesignSettings.shared.plusButton = .hover
        let (strip, window) = Self.strip()
        defer { window.orderOut(nil) }
        let reveal = try #require(HoverReveal.owner(of: strip.newTabButton))
        let rest = TabTunables.restingControlOpacity.value
        #expect(rest > 0 && rest < 1, "a resting control is muted, never hidden: \(rest)")
        #expect(!reveal.isRevealed)
        #expect(abs(strip.newTabButton.alphaValue - rest) < 0.01, "plus at rest: \(strip.newTabButton.alphaValue)")
        reveal.setPointerInside(true)
        reveal.setPointerInside(false)
        // Back at rest it returns to the muted tone, not to hidden.
        #expect(abs(reveal.restAlpha - rest) < 0.01)
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

    @Test func thePanesMoreShowsMutedAtRest() {
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        #expect(!toolbar.view.moreButton.isHidden)
        #expect(abs(toolbar.view.moreButton.alphaValue - TabTunables.restingControlOpacity.value) < 0.01,
                "\"…\" at rest: \(toolbar.view.moreButton.alphaValue)")
    }

    /// Chrome's tab search button: Search Tabs sits in the slot before "…" whatever is selected, and runs
    /// with no tab target (a tab target only reveals that tab). The bar's room counts it, so nothing moves.
    @Test func theBarOffersSearchTabsBeforeMore() throws {
        let registry = ActionRegistry.standard()
        var invocations: [ActionInvocation] = []
        registry.bind("tab.search", invoke: { invocations.append($0) })
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        #expect(toolbar.view.items.map(\.id) == ["tab.search"])
        #expect(toolbar.view.reservedCount == 2, "Search Tabs and \"…\"")
        let button = try #require(toolbar.view.buttons.first)
        _ = button.target?.perform(button.action, with: button)
        #expect(invocations.count == 1)
        #expect(invocations.first?.target == nil)
        toolbar.view.frame = NSRect(x: 0, y: 0, width: toolbar.view.intrinsicContentSize.width, height: 30)
        toolbar.view.layoutSubtreeIfNeeded()
        let searchX = button.frame.minX
        #expect(searchX < toolbar.view.moreButton.frame.minX)
        // A chat selected in a pane with terminals keeps the room; Search Tabs stays in its slot (no "…").
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal])
        #expect(toolbar.view.items.map(\.id) == ["tab.search"])
        #expect(toolbar.view.reservedCount == 2)
        toolbar.view.layoutSubtreeIfNeeded()
        #expect(toolbar.view.buttons.first?.frame.minX == searchX, "Search Tabs moved when \"…\" hid")
        // A pane of chats only (no kind anywhere) has no bar at all.
        toolbar.update(target: "chat", kind: nil)
        #expect(toolbar.view.items.isEmpty)
        #expect(toolbar.view.reservedCount == 0)
    }
}
