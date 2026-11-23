import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextTabs
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-11-15 (CMUX-571): "it should be instant even under load and the f***ing tab not knowing where it should
/// go/the animation not knowing wtf to do is so f***ing stupid". A strip change that comes while an earlier one still
/// moves the tabs (two tabs opened, one of them closed a moment later, with the main thread busy in between) must take
/// every tab straight from where it shows to its new place: no tick moves an edge away from its target, none passes it
/// (motion-first-principles-DESIGN.md principle 5: overshoot is 0 px), and neighbours that move keep the gap between
/// them going one way, from what it showed to what it is at rest.
///
/// Before, the second change stacked a second additive ease-out on the first: with opposite travel the two curves sum
/// to a path that passes the new target and comes back (11 pt at a 90 ms gap on the 200 ms tween).
///
/// Each tick is read from the layers' animations at begin plus k/240 s (`MotionPath`, the render server's own
/// evaluation), with the paths as each change left them, so a later change's removal of a move does not rewrite what
/// the earlier interval showed. The strip lives in pane content in no window (`TabCloseMotionTests`).
@MainActor @Suite(.serialized) struct TabStripRetargetMotionTests {
    /// What one change left on a tab: its paths (valid from the change's begin on, as if nothing else came) and its
    /// place at rest.
    struct Leg {
        let position: MotionPath
        let size: MotionPath
        let anchor: CGPoint
        let rest: CGRect

        init(_ cell: TabCell) {
            position = MotionPath(cell.layer, "position")
            size = MotionPath(cell.layer, "bounds.size")
            anchor = cell.layer.anchorPoint
            rest = cell.layer.frame
        }

        /// Left and right edge shown at media time `time`.
        func edges(at time: CFTimeInterval) -> (minX: CGFloat, maxX: CGFloat) {
            let width = size.value(at: time).x
            let minX = position.value(at: time).x - anchor.x * width
            return (minX, minX + width)
        }

        var end: CFTimeInterval { max(position.end ?? 0, size.end ?? 0) }
    }

    static func legs(_ strip: TabStripView, _ ids: [TabID]) throws -> [TabID: Leg] {
        Dictionary(uniqueKeysWithValues: try ids.map { id in (id, Leg(try #require(strip.cells[id], "\(id.rawValue) has no cell"))) })
    }

    /// Busy main thread for `milliseconds` (the load between the two changes; the moves run on).
    static func stall(milliseconds: Double) {
        let until = CACurrentMediaTime() + milliseconds / 1000
        while CACurrentMediaTime() < until {}
    }

    /// The worst way an edge left its target in [`from`, `to`]: how far it moved away from it between two ticks, and
    /// how far past it it went. Both are 0 for a path that heads straight to the target.
    static func worst(_ leg: Leg, right: Bool, from: CFTimeInterval,
                      to: CFTimeInterval) -> (away: CGFloat, past: CGFloat, tick: Int) {
        let target = right ? leg.rest.maxX : leg.rest.minX
        func edge(_ time: CFTimeInterval) -> CGFloat { right ? leg.edges(at: time).maxX : leg.edges(at: time).minX }
        let ticks = max(1, Int(((to - from) * 240).rounded(.up)))
        var away: CGFloat = 0, past: CGFloat = 0, tick = -1
        var last = target - edge(from)
        for k in 1...ticks {
            let left = target - edge(min(to, from + Double(k) / 240))
            let movedAway = abs(left) - abs(last)
            let passed = left * last < 0 ? abs(left) : 0
            if movedAway > away || passed > past { tick = k }
            away = max(away, movedAway)
            past = max(past, passed)
            last = left
        }
        return (away, past, tick)
    }

    /// Two tabs open at the strip's start and one of them closes `gap` ms later, the main thread busy in between.
    /// Returns the strip, the tabs that stay, and the two changes' legs and begin times.
    static func openThenClose(gap: Double) throws -> (TabCloseMotionTests.Rig, [TabID], [TabID: Leg], CFTimeInterval, [TabID: Leg], CFTimeInterval) {
        let rig = TabCloseMotionTests.rig(TabCloseMotionTests.tabs(3), selected: TabID("tab0"))
        let strip = rig.strip
        let opened = [TabItem(id: TabID("new0"), title: "New 0"), TabItem(id: TabID("new1"), title: "New 1")]
        rig.model.tabs.insert(contentsOf: opened, at: 0)
        strip.sync(fromModel: true)
        rig.pane.layoutSubtreeIfNeeded()
        let staying = [TabID("new1"), TabID("tab0"), TabID("tab1"), TabID("tab2")]
        let first = try legs(strip, staying)
        let firstBegin = try #require(TabCloseMotionTests.latestMoveBegin(staying.compactMap { strip.cells[$0] }), "the open started no strip move")
        stall(milliseconds: gap)
        rig.model.tabs.removeAll { $0.id == TabID("new0") }
        strip.sync(fromModel: true)
        rig.pane.layoutSubtreeIfNeeded()
        let second = try legs(strip, staying)
        let secondBegin = try #require(TabCloseMotionTests.latestMoveBegin(staying.compactMap { strip.cells[$0] }), "the close started no strip move")
        try #require(secondBegin > firstBegin, "SETUP: the close's move does not begin after the open's")
        return (rig, staying, first, firstBegin, second, secondBegin)
    }

    enum Gap: Double, CaseIterable, CustomTestStringConvertible {
        case ms30 = 30, ms60 = 60, ms90 = 90
        var testDescription: String { "\(Int(rawValue)) ms" }
    }

    /// From the second change on, every edge of every tab that stays heads straight to its new place: it never moves
    /// away from it and never passes it. The second change starts where the first left each tab (no jump).
    @Test(arguments: Gap.allCases)
    func aRetargetedTabHeadsStraightToItsNewPlace(_ gap: Gap) throws {
        try TabCloseMotionTests.withMotion(reduce: false) {
            try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
            let (_, staying, first, _, second, begin) = try Self.openThenClose(gap: gap.rawValue)
            for id in staying {
                let was = try #require(first[id]), now = try #require(second[id])
                // No jump where the second change begins: it starts from what the first showed there.
                let shownBefore = was.edges(at: begin), shownAfter = now.edges(at: begin)
                #expect(abs(shownAfter.minX - shownBefore.minX) < 0.5 && abs(shownAfter.maxX - shownBefore.maxX) < 0.5,
                        "\(id.rawValue) jumped from \(shownBefore) to \(shownAfter) when the close began")
                let end = max(now.end, begin) + 1.0 / 120
                for (name, right) in [("left", false), ("right", true)] {
                    let worst = Self.worst(now, right: right, from: begin, to: end)
                    #expect(worst.away < 0.25, "\(id.rawValue) \(name) edge moved \(worst.away) pt away from its new place (tick \(worst.tick))")
                    #expect(worst.past < 0.5, "\(id.rawValue) \(name) edge went \(worst.past) pt past its new place (tick \(worst.tick))")
                }
            }
        }
    }

    /// From the second change on, the gap between two neighbouring tabs that stay goes one way only, from what it
    /// showed when the change began to what it is at rest: no tick opens a hole between them or slides one under the
    /// other further than either end. Every tab still moving restarts on the change's one curve.
    @Test(arguments: Gap.allCases)
    func neighboursKeepOneCurveAfterARetarget(_ gap: Gap) throws {
        try TabCloseMotionTests.withMotion(reduce: false) {
            try #require(Motion.tabs.animatesMovement, "SETUP: animation speed is off on this host")
            let (_, staying, _, _, second, begin) = try Self.openThenClose(gap: gap.rawValue)
            let end = (second.values.map(\.end).max() ?? begin) + 1.0 / 120
            let ticks = Int(((end - begin) * 240).rounded(.up))
            for (leftID, rightID) in zip(staying, staying.dropFirst()) {
                let left = try #require(second[leftID]), right = try #require(second[rightID])
                @MainActor func gapAt(_ time: CFTimeInterval) -> CGFloat { right.edges(at: time).minX - left.edges(at: time).maxX }
                let from = gapAt(begin), rest = right.rest.minX - left.rest.maxX
                let low = min(from, rest) - 0.5, high = max(from, rest) + 0.5
                var worst: (gap: CGFloat, tick: Int)?
                for k in 0...ticks {
                    let shown = gapAt(begin + Double(k) / 240)
                    if shown < low || shown > high, worst.map({ abs(shown - rest) > abs($0.gap - rest) }) ?? true { worst = (shown, k) }
                }
                #expect(worst == nil, "\(leftID.rawValue)|\(rightID.rawValue): the gap went to \(worst?.gap ?? 0) pt at tick \(worst?.tick ?? 0), outside \(from) to \(rest)")
            }
        }
    }
}
