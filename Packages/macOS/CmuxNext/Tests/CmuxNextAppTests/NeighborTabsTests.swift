@testable import CmuxNextApp
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

    /// "Left last" is per window: window 1 leaves W1 for W3, then window 2 leaves W2 for W4. W1 is
    /// still the workspace window 1 left last, so a switch back there wakes nothing. With one
    /// global "left last", window 2's switch parked W1's fronts.
    @Test func eachWindowKeepsItsOwnWorkspaceLeftLast() {
        let objects = (0..<12).map { _ in NSObject() }
        let id = objects.map { ObjectIdentifier($0) }
        let (window1, window2) = (id[0], id[1])
        let (w1, w2, w3, w4, w5) = (id[2], id[3], id[4], id[5], id[6])
        let (p1, p2, p3, p4, p5) = (id[7], id[8], id[9], id[10], id[11])
        var tabs = NeighborTabs()
        tabs.set(p1, order: ["t1"], selected: "t1", group: w1, window: window1)
        tabs.set(p2, order: ["t2"], selected: "t2", group: w2, window: window2)
        tabs.set(p1, order: ["t1"], selected: "t1", visible: false, group: w1, window: window1)
        tabs.set(p3, order: ["t3"], selected: "t3", group: w3, window: window1)
        let moved = tabs.set(p2, order: ["t2"], selected: "t2", visible: false, group: w2, window: window2)
        #expect(moved.isEmpty, "window 2's switch moved another window's fronts: \(moved)")
        tabs.set(p4, order: ["t4"], selected: "t4", group: w4, window: window2)
        #expect(tabs.fronts == ["t1": .warm, "t2": .warm, "t3": .warm, "t4": .warm], "a window lost the workspace it left last")
        // Window 1 goes on to W5: W3 is its workspace left last now, W1 parks.
        tabs.set(p3, order: ["t3"], selected: "t3", visible: false, group: w3, window: window1)
        #expect(tabs.fronts == ["t1": .parked, "t2": .warm, "t3": .warm, "t4": .warm])
        let shown = tabs.set(p5, order: ["t5"], selected: "t5", group: w5, window: window1)
        #expect(shown == ["t5": NeighborTabs.FrontChange(old: nil, new: .warm)], "a pane report returned fronts it did not move")
        withExtendedLifetime(objects) {}
    }

    /// The fronts are kept incrementally (a report touches one pane and one or two groups); a
    /// long seeded run of switches, tab changes, moves and closes in three windows matches a
    /// from-scratch recompute after every step, and each report returns exactly what moved.
    @Test func incrementalFrontsMatchAFullRecompute() {
        let objects = (0..<40).map { _ in NSObject() }
        let id = objects.map { ObjectIdentifier($0) }
        let windows = Array(id[0..<3])
        let groups = Array(id[3..<12]) // three per window
        let panes = Array(id[12..<40])
        var tabs = NeighborTabs()
        var reference = Reference()
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        for step in 0..<3_000 {
            let pane = panes[next(panes.count)]
            let before = tabs.fronts
            let moved: [String: NeighborTabs.FrontChange]
            if next(10) == 0 {
                moved = tabs.remove(pane)
                reference.remove(pane)
            } else {
                let groupIndex = next(groups.count)
                let selected = next(5) == 0 ? nil : "tab\(next(30))"
                let visible = next(3) != 0
                moved = tabs.set(pane, order: selected.map { [$0] } ?? [], selected: selected, visible: visible,
                                 group: groups[groupIndex], window: windows[groupIndex / 3])
                reference.set(pane, selected: selected, visible: visible, group: groups[groupIndex], window: windows[groupIndex / 3])
            }
            let expected = reference.fronts
            #expect(tabs.fronts == expected, "step \(step)")
            let diff = Set(before.keys).union(expected.keys).filter { before[$0] != expected[$0] }
            #expect(Set(moved.keys) == diff, "step \(step): returned moves differ")
            for key in diff { #expect(moved[key] == NeighborTabs.FrontChange(old: before[key], new: expected[key])) }
            if tabs.fronts != expected { break }
        }
        withExtendedLifetime(objects) {}
    }

    /// The fronts recomputed from scratch after every report, as before the incremental model.
    private struct Reference {
        var panes: [ObjectIdentifier: (selected: String?, visible: Bool, group: ObjectIdentifier)] = [:]
        var window: [ObjectIdentifier: ObjectIdentifier] = [:]
        var leftAt: [ObjectIdentifier: UInt64] = [:]
        var leaves: UInt64 = 0

        func onScreen(_ group: ObjectIdentifier) -> Bool { panes.values.contains { $0.group == group && $0.visible } }

        mutating func set(_ pane: ObjectIdentifier, selected: String?, visible: Bool, group: ObjectIdentifier, window: ObjectIdentifier) {
            var touched = [group]
            if let old = panes[pane]?.group, old != group { touched.append(old) }
            let was = touched.map { onScreen($0) }
            panes[pane] = (selected, visible, group)
            self.window[group] = window
            for (group, was) in zip(touched, was) { settle(group, was) }
        }

        mutating func remove(_ pane: ObjectIdentifier) {
            guard let group = panes[pane]?.group else { return }
            let was = onScreen(group)
            panes[pane] = nil
            settle(group, was)
        }

        mutating func settle(_ group: ObjectIdentifier, _ was: Bool) {
            if onScreen(group) || !panes.values.contains(where: { $0.group == group }) {
                leftAt[group] = nil
            } else if was, !isLastLeft(group) {
                leaves += 1
                leftAt[group] = leaves
            }
        }

        func isLastLeft(_ group: ObjectIdentifier) -> Bool {
            guard let stamp = leftAt[group] else { return false }
            return !leftAt.contains { $0.key != group && window[$0.key] == window[group] && $0.value > stamp }
        }

        var fronts: [String: HibernationPlanner.Front] {
            var fronts: [String: HibernationPlanner.Front] = [:]
            for pane in panes.values {
                guard let selected = pane.selected else { continue }
                let warm = onScreen(pane.group) || isLastLeft(pane.group)
                if warm || fronts[selected] == nil { fronts[selected] = warm ? .warm : .parked }
            }
            return fronts
        }
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
