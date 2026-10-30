@testable import CmuxNextApp
import CmuxNextHibernation
import CmuxNextBridge
@testable import CmuxNextSettings
import Foundation
import Testing

/// Neighbor tabs (msg 5402 thread, "a very important nice touch"): the tabs right before and
/// after each pane's shown tab stay awake, so Ctrl-Tab, Cmd-Shift-[ ], Cmd-1...9 and clicks on a
/// nearby tab show a live page. These cover the neighbor set after a switch, a reorder, a close
/// and a move to the last tab, and the setting (`browser.keepNeighborTabsAwake`).
@Suite struct NeighborTabsTests {
    private let pane = ObjectIdentifier(NSObject.self)
    private let other = ObjectIdentifier(NSString.self)
    private let order = ["a", "b", "c", "d", "e"]

    private func awake(_ order: [String], _ selected: String?, radius: Int = 1) -> Set<String> {
        var tabs = NeighborTabs()
        tabs.set(pane, order: order, selected: selected)
        return tabs.awake(radius: radius)
    }

    @Test func theTabsBeforeAndAfterTheShownTabStayAwake() {
        #expect(awake(order, "c") == ["b", "d"])
    }

    @Test func aSwitchMovesTheNeighbors() {
        var tabs = NeighborTabs()
        tabs.set(pane, order: order, selected: "b")
        #expect(tabs.awake(radius: 1) == ["a", "c"])
        tabs.set(pane, order: order, selected: "c")
        #expect(tabs.awake(radius: 1) == ["b", "d"])
    }

    /// Ctrl-Tab and Cmd-Shift-] wrap (`PaneController.selectAdjacent`): the last tab's next
    /// neighbor is the first one, and the first tab's previous neighbor is the last.
    @Test func theLastAndFirstTabsWrapAsCtrlTabDoes() {
        #expect(awake(order, "e") == ["d", "a"])
        #expect(awake(order, "a") == ["e", "b"])
    }

    @Test func aReorderMovesTheNeighbors() {
        #expect(awake(["a", "d", "c", "b", "e"], "c") == ["d", "b"])
    }

    @Test func aCloseMovesTheNeighbors() {
        #expect(awake(["a", "b", "c", "e"], "c") == ["b", "e"])
    }

    @Test func aRadiusOfTwoKeepsTwoOnEachSide() {
        #expect(awake(order, "c", radius: 2) == ["a", "b", "d", "e"])
    }

    @Test func aSmallPaneHasFewerNeighborsAndNeverTheShownTab() {
        #expect(awake(["a", "b"], "a", radius: 3) == ["b"])
        #expect(awake(["a"], "a", radius: 3).isEmpty)
    }

    @Test func aPaneThatShowsNothingHasNoNeighbors() {
        #expect(awake(order, nil).isEmpty)
        #expect(awake(order, "gone").isEmpty)
    }

    /// Two panes: each keeps its own neighbors, and a tab shown in one pane is never "awake"
    /// as the other's neighbor (it is visible, not a candidate).
    @Test func panesKeepTheirOwnNeighbors() {
        var tabs = NeighborTabs()
        tabs.set(pane, order: ["a", "b", "c"], selected: "b")
        tabs.set(other, order: ["x", "y", "a"], selected: "y")
        #expect(tabs.awake(radius: 1) == ["a", "c", "x"])
        tabs.remove(other)
        #expect(tabs.awake(radius: 1) == ["a", "c"])
    }

    @Test func memoryPressureAndLowPowerModeTurnItOff() {
        #expect(NeighborTabs.radius(setting: 2, pressure: .normal, lowPower: false) == 2)
        #expect(NeighborTabs.radius(setting: 2, pressure: .warning, lowPower: false) == 0)
        #expect(NeighborTabs.radius(setting: 2, pressure: .critical, lowPower: false) == 0)
        #expect(NeighborTabs.radius(setting: 2, pressure: .normal, lowPower: true) == 0)
    }

    @Test func oneOnEachSideByDefault() {
        #expect(BrowserHibernationSetting.fallback.neighborRadius == 1)
        let (setting, diagnostics) = BrowserHibernationSetting.parse(.object(["browser": .object([:])]))
        #expect(diagnostics.isEmpty)
        #expect(setting.neighborRadius == 1)
    }

    @Test(arguments: [0, 1, 2, 3])
    func theSettingParses(radius: Int) {
        let (setting, diagnostics) = BrowserHibernationSetting.parse(
            .object(["browser": .object(["keepNeighborTabsAwake": .number(Double(radius))])]))
        #expect(diagnostics.isEmpty)
        #expect(setting.neighborRadius == radius)
    }

    @Test(arguments: [CmuxNextSettings.JSONValue.number(4), .number(1.5), .number(-1), .string("yes")])
    func aBadValueKeepsTheDefault(value: CmuxNextSettings.JSONValue) {
        let (setting, diagnostics) = BrowserHibernationSetting.parse(.object(["browser": .object(["keepNeighborTabsAwake": value])]))
        #expect(setting.neighborRadius == 1)
        #expect(diagnostics.map(\.path) == ["browser.keepNeighborTabsAwake"])
    }
}
