import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The tab bar's trailing end. Leo (2026-10-19) had its controls show muted at rest; Lawrence
/// (2026-10-20) wants the plus and "…" hidden until the pointer is over the tab bar, and the Search Tabs
/// chevron gone from the bar ("i dont like the down arrow"), its action kept in "…"'s menu. The
/// controls keep their room, so nothing moves when they appear. Leo (2026-10-26): the pane’s ⋮
/// fades in place; its normal hover fade must never slide the glyph sideways. Leo (2026-10-20, "the
/// rightmost area has a reservation of hidden icons" / "if you push or hover then you cant access the
/// rightmost tabs"): once the tabs fill the bar, the controls show muted at rest in the room they keep.
@MainActor @Suite(.serialized, .closesItsWindows) struct TabBarRestingControlsTests {
    /// `tabs` 2 leaves room beside them (not crowded); 12 fill the 900-point bar (crowded).
    private static func strip(tabs: Int = 2) -> (TabStripView, NSWindow) {
        let model = TabStripModel(tabs: (0..<tabs).map { TabItem(id: TabID("t\($0)"), title: "Tab \($0)") }, selectedID: TabID("t0"))
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
        defer { window.closeAfterTest() }
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

    /// The pane-type chooser (#27004) sits beside the plus, so it hides, shows and stays for its menu with
    /// it: a hover-only plus never leaves the chevron alone next to an empty slot.
    @Test func thePaneTypeChooserFadesWithThePlus() throws {
        let previousPlusButton = DesignSettings.shared.plusButton
        let previousAnimationSpeed = DesignSettings.shared.animationSpeed
        // This checks the reveal's end states, not the fade's progress on the display clock.
        DesignSettings.shared.animationSpeed = .off
        DesignSettings.shared.plusButton = .hover
        defer {
            DesignSettings.shared.plusButton = previousPlusButton
            DesignSettings.shared.animationSpeed = previousAnimationSpeed
        }
        let (strip, window) = Self.strip()
        defer { window.closeAfterTest() }
        strip.showsNewTabMenuButton = true
        let chooser = strip.newTabMenuButton
        #expect(!chooser.isHidden)
        let reveal = try #require(HoverReveal.owner(of: strip.newTabButton))
        #expect(HoverReveal.owner(of: chooser) === reveal, "the chooser fades with the plus")
        #expect(chooser.alphaValue == strip.newTabButton.alphaValue, "chooser at rest: \(chooser.alphaValue)")
        reveal.setPointerInside(true)
        #expect(chooser.alphaValue == 1)
        reveal.setPointerInside(false)
        let hold = reveal.hold() // an open strip menu, the chooser's own included
        #expect(chooser.alphaValue == 1, "the chooser stays shown while its menu is open")
        hold.release()
        #expect(chooser.alphaValue == reveal.restAlpha)
        DesignSettings.shared.plusButton = .always
        strip.reveal.applyPlusButtonMode()
        #expect(HoverReveal.owner(of: chooser) == nil)
        #expect(chooser.alphaValue == 1, "always keeps the chooser fully shown, like the plus")
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

    /// The native creation actions are offered by the pane's + and "…" menu, never duplicated as
    /// resting buttons. This applies to chat and every other pane kind.
    @Test func creationActionsAreNeverRestingButtons() {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry }, newTabMenu: { nil },
                                   paneTarget: ActionTargetRef(kind: .pane, id: "pane"))
        let kinds: [PaneToolbar.Kind?] = [.newTab, .terminal, .browser, .other, nil]
        for (index, kind) in kinds.enumerated() {
            toolbar.update(target: "pane-\(index)", kind: kind)
            #expect(toolbar.view.items.map(\.id).filter { PaneToolbar.creationActions.map(\.rawValue).contains($0) }.isEmpty)
        }
    }

    /// New Tab and the chat pane share this toolbar. Revealing it changes opacity alone,
    /// including the exit and Reduce Motion.
    @Test(arguments: [PaneToolbar.Kind.newTab, .terminal], [false, true])
    func moreFadesInPlace(kind: PaneToolbar.Kind, reduceMotion: Bool) {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: kind)
        let view = toolbar.view
        view.frame = NSRect(x: 0, y: 0, width: view.intrinsicContentSize.width, height: 30)
        view.layoutSubtreeIfNeeded()
        let resting = view.moreButton.frame
        #expect(resting.maxX <= view.bounds.width, "⋮ sits inside its trailing slot")
        #expect(resting.minX >= 0, "⋮ never waits outside its hit target")
        view.reveal.setPointerInside(true)
        #expect(view.moreButton.frame == resting, "revealing ⋮ must not move it right")
        view.reveal.setPointerInside(false)
        #expect(view.moreButton.frame == resting, "fading out ⋮ must not move it left")
        #expect(view.moreButton.alphaValue == view.reveal.restAlpha, "the normal fade still hides ⋮")
    }
    private static func setCrowdedControls(_ mode: TabCrowdedControls?) {
        TunableStore.shared.set(TabTunables.crowdedControls.key, mode.map { .choice($0.rawValue) })
    }

    /// 12 tabs fill the bar: the plus rests muted in its kept room instead of leaving an empty strip,
    /// and revealing it moves no tab, so the rightmost tab stays where the pointer finds it.
    @Test func aCrowdedStripsPlusShowsAtRestAndItsRevealMovesNoTab() throws {
        DesignSettings.shared.plusButton = .hover
        Self.setCrowdedControls(nil)
        let (strip, window) = Self.strip(tabs: 12)
        defer { window.closeAfterTest() }
        #expect(strip.isCrowded, "12 tabs in 900 points are narrower than their widest")
        let reveal = try #require(HoverReveal.owner(of: strip.newTabButton))
        let muted = TabTunables.crowdedControlOpacity.value
        #expect(muted > 0)
        #expect(abs(strip.newTabButton.alphaValue - muted) < 0.01, "plus at rest when crowded: \(strip.newTabButton.alphaValue)")
        let last = try #require(strip.result.slots.last)
        let clip = strip.tabsClip.frame
        reveal.setPointerInside(true)
        #expect(strip.newTabButton.alphaValue == 1)
        strip.layoutSubtreeIfNeeded()
        #expect(strip.tabsClip.frame == clip, "the reveal never narrows the tabs")
        #expect(strip.result.slots.last == last, "the rightmost tab keeps its place under the pointer")
        #expect(strip.newTabButton.frame.minX >= strip.tabsClip.frame.maxX - 0.5, "the plus never covers a tab")
        reveal.setPointerInside(false)
        #expect(abs(strip.newTabButton.alphaValue - muted) < 0.01)
    }

    /// A strip with room beside its tabs keeps Lawrence's hidden-at-rest controls; closing down to it
    /// hides them again.
    @Test func aStripWithRoomKeepsItsControlsHiddenAtRest() throws {
        DesignSettings.shared.plusButton = .hover
        Self.setCrowdedControls(nil)
        let (strip, window) = Self.strip(tabs: 2)
        defer { window.closeAfterTest() }
        #expect(!strip.isCrowded)
        #expect(strip.newTabButton.alphaValue == 0)
    }

    /// The pane's "…" follows its strip: hidden beside a strip with room, muted beside a crowded one.
    @Test func thePanesMoreFollowsItsStripsCrowding() {
        Self.setCrowdedControls(nil)
        let toolbar = PaneToolbar(registry: { nil }, newTabMenu: { nil })
        toolbar.update(target: "tab0", kind: .terminal)
        let more = toolbar.view.moreButton
        let (roomy, roomyWindow) = Self.strip(tabs: 2)
        defer { roomyWindow.closeAfterTest() }
        toolbar.view.strip = roomy
        #expect(more.alphaValue == 0, "\"…\" beside tabs with room: \(more.alphaValue)")
        let (crowded, crowdedWindow) = Self.strip(tabs: 12)
        defer { crowdedWindow.closeAfterTest() }
        toolbar.view.strip = crowded
        #expect(abs(more.alphaValue - TabTunables.crowdedControlOpacity.value) < 0.01, "\"…\" beside a full bar: \(more.alphaValue)")
    }

    /// The three versions (`tabs.crowdedControls`): shown when crowded (default), always shown, hidden at rest.
    @Test func eachVersionsRestingOpacity() {
        defer { Self.setCrowdedControls(nil) }
        let muted = TabTunables.crowdedControlOpacity.value
        Self.setCrowdedControls(nil)
        #expect(TabTunables.crowdedControls.value == .shownWhenCrowded)
        #expect(TabTunables.restingControlAlpha(crowded: false) == 0)
        #expect(TabTunables.restingControlAlpha(crowded: true) == muted)
        Self.setCrowdedControls(.alwaysShown)
        #expect(TabTunables.restingControlAlpha(crowded: false) == muted)
        Self.setCrowdedControls(.hiddenAtRest)
        #expect(TabTunables.restingControlAlpha(crowded: true) == 0)
    }
}
