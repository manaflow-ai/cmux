import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextTabs
import CmuxNextTestSupport
import Testing

/// The tab bar's trailing end. Leo (2026-10-19) had its controls show muted at rest; Lawrence
/// (2026-10-20) wants the plus and the pinned buttons hidden until the pointer is over the tab bar, and the
/// Search Tabs chevron gone from the bar ("i dont like the down arrow"), its action kept in a menu (the tab
/// bar's right-click, now that the pane's "…" is gone, user 2026-11-13). The controls keep their room, so
/// nothing moves when they appear. Leo (2026-10-26): a control fades in place; its normal hover fade must
/// never slide the glyph sideways. Leo (2026-10-20, "the rightmost area has a reservation of hidden icons" /
/// "if you push or hover then you cant access the rightmost tabs"): once the tabs fill the bar, the controls
/// show muted at rest in the room they keep.
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

    /// The pane-type chooser (#27004) sits beside the plus. With `tabs.chevronOnHover` off it hides, shows and stays
    /// for its menu with the plus: a hover-only plus never leaves the chevron alone next to an empty slot.
    @Test func thePaneTypeChooserFadesWithThePlusWhenNotHoverOnly() throws {
        let previousPlusButton = DesignSettings.shared.plusButton
        let previousAnimationSpeed = DesignSettings.shared.animationSpeed
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TabTunables.all)
        let previousChevron = TunableStore.shared.override(TabTunables.chevronOnHover.key)
        try #require(TunableStore.shared.set(TabTunables.chevronOnHover.key, .bool(false)) == .bool(false))
        // This checks the reveal's end states, not the fade's progress on the display clock.
        DesignSettings.shared.animationSpeed = .off
        DesignSettings.shared.plusButton = .hover
        defer {
            DesignSettings.shared.plusButton = previousPlusButton
            DesignSettings.shared.animationSpeed = previousAnimationSpeed
            _ = TunableStore.shared.set(TabTunables.chevronOnHover.key, previousChevron)
        }
        let (strip, window) = Self.strip()
        defer { window.closeAfterTest() }
        strip.showsNewTabMenuButton = true
        strip.reveal.applyPlusButtonMode()
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

    /// The default (`tabs.chevronOnHover`, Lucas 2026-11-12, #41212: "the chevron should only show up when the + button
    /// is hovered directly"): a hover anywhere on the strip shows the + but not the ⌄; the ⌄ shows for its own menu
    /// and keeps its slot (alpha only), so nothing moves as it shows.
    @Test func thePaneTypeChooserShowsOnlyForThePlusOrItsMenuByDefault() throws {
        let previousPlusButton = DesignSettings.shared.plusButton
        let previousAnimationSpeed = DesignSettings.shared.animationSpeed
        TunableStore.shared.activate(file: nil)
        TunableStore.shared.register(TabTunables.all)
        let previousChevron = TunableStore.shared.override(TabTunables.chevronOnHover.key)
        _ = TunableStore.shared.set(TabTunables.chevronOnHover.key, nil)
        DesignSettings.shared.animationSpeed = .off
        DesignSettings.shared.plusButton = .hover
        defer {
            DesignSettings.shared.plusButton = previousPlusButton
            DesignSettings.shared.animationSpeed = previousAnimationSpeed
            _ = TunableStore.shared.set(TabTunables.chevronOnHover.key, previousChevron)
        }
        #expect(TabTunables.chevronOnHover.value)
        let (strip, window) = Self.strip()
        defer { window.closeAfterTest() }
        strip.showsNewTabMenuButton = true
        strip.reveal.applyPlusButtonMode()
        let chooser = strip.newTabMenuButton
        #expect(!chooser.isHidden, "it keeps its slot")
        let slot = chooser.frame
        let reveal = try #require(HoverReveal.owner(of: strip.newTabButton))
        #expect(HoverReveal.owner(of: chooser) == nil, "the ⌄ stays out of the strip's reveal")
        #expect(chooser.alphaValue == 0)
        reveal.setPointerInside(true)
        #expect(strip.newTabButton.alphaValue == 1, "a hover on the strip shows the +")
        #expect(chooser.alphaValue == 0, "but not the ⌄")
        chooser.isHighlighted = true // its menu is open
        strip.updateChooserReveal()
        #expect(chooser.alphaValue == 1, "the ⌄ shows while its menu is open")
        chooser.isHighlighted = false
        strip.updateChooserReveal()
        #expect(chooser.alphaValue == 0)
        #expect(chooser.frame == slot, "showing and hiding moves nothing")
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

    /// A pane toolbar with Split Right pinned (`tabs.toolbarButtons`): its one resting control now that "…" is gone.
    private static func pinned(_ kind: PaneToolbar.Kind = .terminal) -> PaneToolbar {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        registry.bind("splitRight", invoke: { _ in })
        let toolbar = PaneToolbar(registry: { registry })
        toolbar.update(target: "tab0", kind: kind, pinned: ["splitRight"])
        return toolbar
    }

    @Test func aPinHidesAtRestAndStaysForAMenuHold() throws {
        let toolbar = Self.pinned()
        let pin = try #require(toolbar.view.buttons.first)
        #expect(!pin.isHidden)
        #expect(pin.alphaValue == 0, "a pin at rest: \(pin.alphaValue)")
        // An open menu holds the reveal (the pointer leaves the bar for the menu).
        let hold = toolbar.view.reveal.hold()
        #expect(toolbar.view.reveal.isRevealed)
        hold.release()
        #expect(!toolbar.view.reveal.isRevealed)
    }

    /// The chevron (Search Tabs) is gone from the bar, and so is "…": the tab bar's right-click runs it with no tab
    /// target (a tab target only reveals that tab). With nothing pinned the bar keeps no room at all.
    @Test func searchTabsIsInTheTabBarMenu() throws {
        let registry = ActionRegistry.standard()
        var invocations: [ActionInvocation] = []
        registry.bind("tab.search", invoke: { invocations.append($0) })
        let toolbar = PaneToolbar(registry: { registry })
        toolbar.update(target: "tab0", kind: .terminal)
        #expect(!toolbar.view.items.map(\.id).contains("tab.search"), "no chevron in the bar")
        #expect(toolbar.view.buttons.isEmpty)
        #expect(toolbar.view.reservedCount == 0, "no \"…\" either")
        let row = try #require(toolbar.tabBarMenuRows().joined().first { ActionRegistry.menuRun(of: $0)?.id == "tab.search" },
                               "Search Tabs in the tab bar's right-click")
        #expect(ActionRegistry.menuRun(of: row)?.target == nil)
        _ = row.target?.perform(row.action, with: row)
        #expect(invocations.count == 1)
        #expect(invocations.first?.target == nil)
        toolbar.update(target: "chat", kind: nil, paneKinds: [.terminal])
        #expect(toolbar.view.items.isEmpty)
        #expect(toolbar.view.reservedCount == 0)
    }

    /// The native creation actions are offered by the pane's + and the tab bar's right-click, never duplicated as
    /// resting buttons. This applies to chat and every other pane kind.
    @Test func creationActionsAreNeverRestingButtons() {
        let registry = ActionRegistry.standard()
        let toolbar = PaneToolbar(registry: { registry },
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
    func aPinFadesInPlace(kind: PaneToolbar.Kind, reduceMotion: Bool) throws {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        let toolbar = Self.pinned(kind)
        let view = toolbar.view
        view.frame = NSRect(x: 0, y: 0, width: view.intrinsicContentSize.width, height: 30)
        view.layoutSubtreeIfNeeded()
        let pin = try #require(view.buttons.first)
        let resting = pin.frame
        #expect(resting.maxX <= view.bounds.width, "the pin sits inside its trailing slot")
        #expect(resting.minX >= 0, "the pin never waits outside its hit target")
        view.reveal.setPointerInside(true)
        #expect(pin.frame == resting, "revealing the pin must not move it right")
        view.reveal.setPointerInside(false)
        #expect(pin.frame == resting, "fading out the pin must not move it left")
        #expect(pin.alphaValue == view.reveal.restAlpha, "the normal fade still hides the pin")
    }
    /// 12 tabs fill the bar: the plus rests muted in its kept room instead of leaving an empty strip,
    /// and revealing it moves no tab, so the rightmost tab stays where the pointer finds it.
    @Test func aCrowdedStripsPlusShowsAtRestAndItsRevealMovesNoTab() throws {
        let previousPlusButton = DesignSettings.shared.plusButton
        let previousAnimationSpeed = DesignSettings.shared.animationSpeed
        // This checks the reveal's end states, not the fade's progress on the display clock: on a
        // window with a screen the hover fade animates and the plus still reads its resting alpha.
        DesignSettings.shared.animationSpeed = .off
        DesignSettings.shared.plusButton = .hover
        defer {
            DesignSettings.shared.plusButton = previousPlusButton
            DesignSettings.shared.animationSpeed = previousAnimationSpeed
        }
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
        let (strip, window) = Self.strip(tabs: 2)
        defer { window.closeAfterTest() }
        #expect(!strip.isCrowded)
        #expect(strip.newTabButton.alphaValue == 0)
    }

    /// The pane's pins follow its strip: hidden beside a strip with room, muted beside a crowded one.
    @Test func thePanesPinsFollowTheirStripsCrowding() throws {
        let toolbar = Self.pinned()
        let pin = try #require(toolbar.view.buttons.first)
        let (roomy, roomyWindow) = Self.strip(tabs: 2)
        defer { roomyWindow.closeAfterTest() }
        toolbar.view.strip = roomy
        #expect(pin.alphaValue == 0, "a pin beside tabs with room: \(pin.alphaValue)")
        let (crowded, crowdedWindow) = Self.strip(tabs: 12)
        defer { crowdedWindow.closeAfterTest() }
        toolbar.view.strip = crowded
        #expect(abs(pin.alphaValue - TabTunables.crowdedControlOpacity.value) < 0.01, "a pin beside a full bar: \(pin.alphaValue)")
    }

    /// The three versions (`tabs.crowdedControls`): shown when crowded (default), always shown, hidden at rest.
    @Test func eachVersionsRestingOpacity() {
        let store = TunableStore()
        store.register(TabTunables.all)
        store.activate(file: nil)
        let muted = TabTunables.crowdedControlOpacity.value(in: store)
        #expect(TabTunables.crowdedControls.value(in: store) == .shownWhenCrowded)
        #expect(TabTunables.restingControlAlpha(crowded: false, in: store) == 0)
        #expect(TabTunables.restingControlAlpha(crowded: true, in: store) == muted)
        store.set(TabTunables.crowdedControls.key, .choice(TabCrowdedControls.alwaysShown.rawValue))
        #expect(TabTunables.restingControlAlpha(crowded: false, in: store) == muted)
        store.set(TabTunables.crowdedControls.key, .choice(TabCrowdedControls.hiddenAtRest.rawValue))
        #expect(TabTunables.restingControlAlpha(crowded: true, in: store) == 0)
    }
}
