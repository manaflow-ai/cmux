import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextTabs

@Suite("Tab chrome visibility")
struct VisibilityTests {
    private func resolve(_ width: CGFloat, pinned: Bool = false, selected: Bool = false, hovered: Bool = false, style: TabStripStyle = .chrome) -> TabChromeVisibility {
        TabChromeVisibility.resolve(width: width, isPinned: pinned, isSelected: selected, isHovered: hovered, style: style)
    }

    @Test func wideTabsShowEverything() {
        let v = resolve(200)
        #expect(v.showsIcon && v.showsTitle && v.showsClose && !v.centersContent)
    }

    @Test func narrowInactiveTabHidesClose() {
        let v = resolve(80)
        #expect(!v.showsClose)
        #expect(v.showsTitle)
    }

    @Test func hoverRevealsCloseOnNarrowTab() {
        #expect(resolve(80, hovered: true).showsClose)
        #expect(resolve(40, hovered: true).showsClose)
    }

    @Test func tinyActiveTabShowsOnlyCloseCentered() {
        let v = resolve(40, selected: true)
        #expect(v.showsClose)
        #expect(!v.showsIcon)
        #expect(!v.showsTitle)
        #expect(v.centersContent)
    }

    @Test func minActiveWidthFitsIconAndClose() {
        let v = resolve(TabStripMetrics.standard.minActiveTabWidth, selected: true)
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

    @Test func compactShowsCloseOnlyOnSelectedOrHovered() {
        #expect(!resolve(160, style: .compact).showsClose)
        #expect(resolve(160, hovered: true, style: .compact).showsClose)
        #expect(resolve(160, selected: true, style: .compact).showsClose)
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

    @Test func criticallyDampedDoesNotOvershoot() {
        var spring = Spring(value: 0, response: 0.3, dampingRatio: 1)
        spring.target = 100
        var peak: CGFloat = 0
        for _ in 0..<240 {
            spring.step(1.0 / 120.0)
            peak = max(peak, spring.value)
        }
        #expect(peak <= 100.01)
    }
}

@Suite("Hover card timing")
struct HoverCardPolicyTests {
    let policy = HoverCardPolicy()

    @Test func narrowTabsShowSooner() {
        let m = TabStripMetrics.standard
        #expect(policy.showDelay(tabWidth: m.minInactiveTabWidth) == .milliseconds(300))
        #expect(policy.showDelay(tabWidth: m.maxTabWidth) == .milliseconds(800))
        #expect(policy.showDelay(tabWidth: 20) == .milliseconds(300))
        let middle = policy.showDelay(tabWidth: (m.minInactiveTabWidth + m.maxTabWidth) / 2)
        #expect(middle == .milliseconds(550))
    }

    @Test func visibleCardUpdatesImmediately() {
        #expect(policy.delay(tabWidth: 240, cardIsVisible: true, sinceLastHidden: nil) == .zero)
    }

    @Test func recentlyHiddenCardReshowsImmediately() {
        #expect(policy.delay(tabWidth: 240, cardIsVisible: false, sinceLastHidden: .milliseconds(200)) == .zero)
        #expect(policy.delay(tabWidth: 240, cardIsVisible: false, sinceLastHidden: .seconds(2)) == .milliseconds(800))
        #expect(policy.delay(tabWidth: 240, cardIsVisible: false, sinceLastHidden: nil) == .milliseconds(800))
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
