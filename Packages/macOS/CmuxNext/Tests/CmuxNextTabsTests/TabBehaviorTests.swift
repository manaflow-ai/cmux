import CoreGraphics
import Foundation
import CmuxNextDesign
import Testing
@testable import CmuxNextTabs

@Suite("Tab chrome visibility")
struct VisibilityTests {
    private func resolve(_ width: CGFloat, pinned: Bool = false, selected: Bool = false, hovered: Bool = false, style: TabStripStyle = .chrome) -> TabChromeVisibility {
        TabChromeVisibility.resolve(width: width, isPinned: pinned, isSelected: selected, isHovered: hovered, style: style, metrics: m)
    }

    @Test func wideTabsShowIconAndTitleButNoCloseUntilHovered() {
        let v = resolve(200)
        #expect(v.showsIcon && v.showsTitle && !v.showsClose && !v.centersContent)
        #expect(resolve(200, hovered: true).showsClose)
    }

    /// User feedback (nxdog9): the x shows only on the hovered tab, also
    /// not on a wide selected tab while the pointer is elsewhere. A narrow
    /// selected tab keeps it (nxdog13).
    @Test func selectedTabShowsCloseOnlyWhileHoveredUntilItIsNarrow() {
        #expect(!resolve(200, selected: true).showsClose)
        #expect(resolve(200, selected: true, hovered: true).showsClose)
        #expect(resolve(m.minActiveTabWidth, selected: true).showsClose)
    }

    @Test func narrowInactiveTabHidesClose() {
        let v = resolve(80)
        #expect(!v.showsClose)
        #expect(v.showsTitle)
    }

    /// The 68 pt contents threshold (10 + 68 + 6 with these metrics).
    @Test func hoverRevealsCloseFromTheContentsWidthThreshold() {
        #expect(resolve(84, hovered: true).showsClose)
        #expect(!resolve(80, hovered: true).showsClose)
        #expect(!resolve(40, hovered: true).showsClose)
    }

    @Test func tinyHoveredActiveTabShowsOnlyCloseCentered() {
        let v = resolve(40, selected: true, hovered: true)
        #expect(v.showsClose)
        #expect(!v.showsIcon)
        #expect(!v.showsTitle)
        #expect(v.centersContent)
    }

    @Test func tokenDerivedMinActiveWidthFitsIconAndClose() {
        let tokens = TabStripMetrics.standard
        let v = TabChromeVisibility.resolve(width: tokens.minActiveTabWidth, isPinned: false, isSelected: true, isHovered: true, style: .chrome, metrics: tokens)
        #expect(v.showsIcon && v.showsClose)
    }

    @Test func minActiveWidthFitsIconAndClose() {
        let v = resolve(m.minActiveTabWidth, selected: true, hovered: true)
        #expect(v.showsIcon && v.showsClose)
    }

    @Test func tinyInactiveTabIsIconOnlyCentered() {
        let v = resolve(40)
        #expect(v.showsIcon && !v.showsTitle && !v.showsClose && v.centersContent)
    }

    @Test func pinnedIsIconOnly() {
        let v = resolve(40, pinned: true, selected: true, hovered: true)
        #expect(v.showsIcon && !v.showsTitle && !v.showsClose && v.centersContent)
    }

    @Test func compactShowsCloseOnlyOnTheHoveredTab() {
        #expect(!resolve(160, style: .compact).showsClose)
        #expect(resolve(160, hovered: true, style: .compact).showsClose)
        #expect(!resolve(160, selected: true, style: .compact).showsClose)
    }
}

@Suite("Drag reorder math")
struct ReorderTests {
    @Test func staysInPlaceWithoutMovement() {
        // Dragged tab (index 2) sits exactly in its slot.
        #expect(TabReorderMath.insertionIndex(draggedMinX: 200, groupStart: 0, otherWidths: [100, 100, 100, 100]) == 2)
    }

    @Test func crossesHalfwayToSwap() {
        #expect(TabReorderMath.insertionIndex(draggedMinX: 249, groupStart: 0, otherWidths: [100, 100, 100, 100]) == 2)
        #expect(TabReorderMath.insertionIndex(draggedMinX: 251, groupStart: 0, otherWidths: [100, 100, 100, 100]) == 3)
        #expect(TabReorderMath.insertionIndex(draggedMinX: 149, groupStart: 0, otherWidths: [100, 100, 100, 100]) == 1)
    }

    @Test func clampsToEnds() {
        #expect(TabReorderMath.insertionIndex(draggedMinX: -500, groupStart: 0, otherWidths: [100, 100]) == 0)
        #expect(TabReorderMath.insertionIndex(draggedMinX: 5000, groupStart: 0, otherWidths: [100, 100]) == 2)
    }

    @Test func respectsGroupStartAndMixedWidths() {
        // Unpinned group starting after pinned tabs.
        #expect(TabReorderMath.insertionIndex(draggedMinX: 86, groupStart: 86, otherWidths: [56, 40, 40]) == 0)
        #expect(TabReorderMath.insertionIndex(draggedMinX: 140, groupStart: 86, otherWidths: [56, 40, 40]) == 1)
        #expect(TabReorderMath.insertionIndex(draggedMinX: 170, groupStart: 86, otherWidths: [56, 40, 40]) == 2)
    }
}

@Suite("Spring")
struct SpringTests {
    @Test func convergesAndSettles() {
        var spring = Spring(value: 0)
        spring.target = 100
        var elapsed: CGFloat = 0
        while !spring.isSettled, elapsed < 3 {
            spring.step(1.0 / 120.0)
            elapsed += 1.0 / 120.0
        }
        #expect(spring.value == 100)
        #expect(spring.velocity == 0)
        #expect(elapsed < 1)
    }

    @Test func frameRateIndependent() {
        var fast = Spring(value: 0)
        var slow = Spring(value: 0)
        fast.target = 100
        slow.target = 100
        for _ in 0..<24 { fast.step(1.0 / 120.0) }
        for _ in 0..<12 { slow.step(1.0 / 60.0) }
        #expect(abs(fast.value - slow.value) < 0.5)
    }

    @Test func retargetKeepsVelocity() {
        var spring = Spring(value: 0)
        spring.target = 100
        for _ in 0..<5 { spring.step(1.0 / 120.0) }
        let velocity = spring.velocity
        spring.target = 50
        #expect(spring.velocity == velocity)
        #expect(velocity > 0)
    }

    /// Damping 0.9 overshoots 0.05%: 0.1 pt on a 200 pt move, below a pixel.
    @Test func overshootStaysBelowAPixel() {
        var spring = Spring(value: 0, token: .move)
        spring.target = 100
        var peak: CGFloat = 0
        for _ in 0..<240 {
            spring.step(1.0 / 120.0)
            peak = max(peak, spring.value)
        }
        #expect(peak <= 100.1)
    }

    @Test func closingUsesTheFasterDisappearSpring() {
        var spring = Spring(value: 120, token: .move)
        #expect(spring.activeToken == .move)
        spring.target = 0
        #expect(spring.activeToken == .disappear)
    }

    @Test func draggedValueFollowsThePointerAndReleaseCarriesItsVelocity() {
        var spring = Spring(value: 0)
        // Pointer at 600 pt/s, sampled at 120 Hz.
        for frame in 0...6 { spring.follow(CGFloat(frame) * 5, at: Double(frame) / 120.0) }
        #expect(spring.value == 30)
        #expect(spring.target == 30)
        #expect(spring.velocity > 500 && spring.velocity < 700)
        // Release into a slot behind the pointer: the tab keeps moving
        // forward for a moment before it settles back.
        spring.release(at: 6.0 / 120.0 + 0.01)
        #expect(spring.token == .settle)
        spring.target = 10
        spring.step(1.0 / 120.0)
        #expect(spring.value > 30)
        while !spring.isSettled { spring.step(1.0 / 120.0) }
        #expect(spring.value == 10)
        #expect(spring.token == .move, "the release spring ends with the release")
    }

    @Test func releaseAfterThePointerStoppedStartsAtRest() {
        var spring = Spring(value: 0)
        for frame in 0...6 { spring.follow(CGFloat(frame) * 5, at: Double(frame) / 120.0) }
        spring.release(at: 1)
        #expect(spring.velocity == 0)
    }
}

@Suite("Hover card timing")
struct HoverCardPolicyTests {
    let policy = HoverCardPolicy()

    @Test func narrowTabsShowSooner() {
        #expect(policy.showDelay(tabWidth: m.minInactiveTabWidth, metrics: m) == .milliseconds(300))
        #expect(policy.showDelay(tabWidth: m.maxTabWidth, metrics: m) == .milliseconds(800))
        #expect(policy.showDelay(tabWidth: 20, metrics: m) == .milliseconds(300))
        let middle = policy.showDelay(tabWidth: (m.minInactiveTabWidth + m.maxTabWidth) / 2, metrics: m)
        #expect(middle == .milliseconds(550))
    }

    @Test func visibleCardUpdatesImmediately() {
        #expect(policy.delay(tabWidth: 240, cardIsVisible: true, sinceLastHidden: nil) == .zero)
    }

    @Test func recentlyHiddenCardReshowsImmediately() {
        #expect(policy.delay(tabWidth: 240, cardIsVisible: false, sinceLastHidden: .milliseconds(200)) == .zero)
        #expect(policy.delay(tabWidth: 240, cardIsVisible: false, sinceLastHidden: .seconds(2), metrics: m) == .milliseconds(800))
        #expect(policy.delay(tabWidth: 240, cardIsVisible: false, sinceLastHidden: nil, metrics: m) == .milliseconds(800))
    }
}

@MainActor
@Suite("Model")
struct ModelTests {
    private func model() -> TabStripModel {
        let tabs = ["a", "b", "c", "d"].map { TabItem(id: TabID($0), title: $0) }
        return TabStripModel(tabs: tabs, selectedID: "b")
    }

    private var counter = 0
    private func make() -> TabItem { TabItem(id: TabID(UUID().uuidString), title: "new") }

    @Test func orderedTabsPutsPinnedFirst() {
        let model = model()
        model.tabs[2].isPinned = true
        #expect(model.orderedTabs.map(\.id.rawValue) == ["c", "a", "b", "d"])
    }

    @Test func closingSelectedSelectsRightNeighborThenLeft() {
        #expect(TabStripModel.selectionAfterClosing("b", in: ["a", "b", "c"], selected: "b") == "c")
        #expect(TabStripModel.selectionAfterClosing("c", in: ["a", "b", "c"], selected: "c") == "b")
        #expect(TabStripModel.selectionAfterClosing("a", in: ["a"], selected: "a") == nil)
        #expect(TabStripModel.selectionAfterClosing("a", in: ["a", "b"], selected: "b") == "b")
    }

    @Test func applyClose() {
        let model = model()
        model.apply(.close("b", source: .mouse), makeTab: make)
        #expect(model.tabs.map(\.id.rawValue) == ["a", "c", "d"])
        #expect(model.selectedID == "c")
    }

    @Test func applyReorderUsesDisplayIndices() {
        let model = model()
        model.apply(.reorder("a", from: 0, to: 2), makeTab: make)
        #expect(model.tabs.map(\.id.rawValue) == ["b", "c", "a", "d"])
    }

    @Test func applyPinMovesToEndOfPinnedGroup() {
        let model = model()
        model.apply(.pin("c"), makeTab: make)
        model.apply(.pin("a"), makeTab: make)
        #expect(model.orderedTabs.map(\.id.rawValue) == ["c", "a", "b", "d"])
        model.apply(.unpin("c"), makeTab: make)
        #expect(model.orderedTabs.map(\.id.rawValue) == ["a", "c", "b", "d"])
        #expect(model.tabs.map(\.id.rawValue) == ["a", "c", "b", "d"])
    }

    @Test func applyCloseOthersKeepsPinned() {
        let model = model()
        model.apply(.pin("d"), makeTab: make)
        model.apply(.closeOthers(keeping: "b"), makeTab: make)
        #expect(model.orderedTabs.map(\.id.rawValue) == ["d", "b"])
    }

    @Test func applyCloseToRight() {
        let model = model()
        model.selectedID = "d"
        model.apply(.closeToRight(of: "b"), makeTab: make)
        #expect(model.tabs.map(\.id.rawValue) == ["a", "b"])
        #expect(model.selectedID == "b")
    }

    @Test func applyNewTabAfterAndAppend() {
        let model = model()
        model.apply(.newTab(after: "a"), makeTab: { TabItem(id: "n1", title: "n1") })
        model.apply(.newTab(after: nil), makeTab: { TabItem(id: "n2", title: "n2") })
        #expect(model.tabs.map(\.id.rawValue) == ["a", "n1", "b", "c", "d", "n2"])
        #expect(model.selectedID == "n2")
    }

    @Test func appOnlyIntentsAreNotApplied() {
        let model = model()
        #expect(!model.apply(.rename("a"), makeTab: make))
        #expect(!model.apply(.moveToNewSplit("a", .right), makeTab: make))
        #expect(!model.apply(.moveToNewColumn("a"), makeTab: make))
    }

    @Test func sendForwardsToHandler() {
        let model = model()
        var received: [TabStripIntent] = []
        model.intentHandler = { received.append($0) }
        model.send(.select("c"))
        #expect(received == [.select("c")])
        #expect(model.selectedID == "b")
    }
}

@MainActor
@Suite("Design tokens", .serialized)
struct TokenTests {
    @Test func overridesFlowIntoStripMetricsLive() {
        let settings = DesignSettings.shared
        let before = TabStripMetrics()
        settings.setOverride(.tabMaxWidth, 300)
        defer { settings.setOverride(.tabMaxWidth, nil) }
        let after = TabStripMetrics()
        #expect(after.maxTabWidth == 300)
        #expect(after.compactTabWidth == 225)
        #expect(before.maxTabWidth != 300)
    }

    @Test func stripHeightOverrideRecentersTabs() {
        let settings = DesignSettings.shared
        settings.setOverride(.tabStripHeight, 36)
        defer { settings.setOverride(.tabStripHeight, nil) }
        let metrics = TabStripMetrics()
        #expect(metrics.stripHeight == 36)
        #expect(metrics.stripVerticalPadding == (36 - metrics.tabHeight) / 2)
    }

    @Test func comfortableDensityIsRoomier() {
        let settings = DesignSettings.shared
        // Pin both densities and restore the caller's: DensityTests, running in
        // parallel, may be suspended with `.comfortable` set.
        let saved = settings.density
        defer { settings.density = saved }
        settings.density = .compact
        let compact = TabStripMetrics()
        settings.density = .comfortable
        let comfortable = TabStripMetrics()
        #expect(comfortable.tabHeight > compact.tabHeight)
        #expect(comfortable.maxTabWidth > compact.maxTabWidth)
        #expect(comfortable.minActiveTabWidth > compact.minActiveTabWidth)
    }
}
