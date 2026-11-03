import CoreGraphics
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import Testing

/// Leo 2026-10-21: "when you create a workspace at the top it's a huge cascade". The rows below a new workspace row
/// make room by the chosen `sidebar.insertMotion` (`SidebarInsertMotion`): by default they land in place while
/// the new row fades in, so a top insert does not cascade through the list.
@MainActor
struct SidebarInsertMotionTests {
    /// A 28 pt workspace row at the top of a list whose first row stood at y 8.
    private static let newRow = CGRect(x: 8, y: 8, width: 220, height: 28)
    /// The row that was first, before and after the insert.
    private static let below = (was: CGRect(x: 8, y: 8, width: 220, height: 28), now: CGRect(x: 8, y: 36, width: 220, height: 28))

    @Test func theDefaultIsTheSnap() {
        #expect(SidebarInsertMotion.tunable.defaultValue == .snap)
        #expect(SidebarInsertMotion.nudgeDistance.defaultValue == 6)
        #expect(SidebarTunables.all.contains { $0.key == "sidebar.insertMotion" })
        #expect(SidebarTunables.all.contains { $0.key == "sidebar.insertMotion.nudge" })
    }

    /// The row below starts the nudge above its slot, not a row height above it.
    @Test func aRowBelowATopInsertTravelsAtMostTheNudge() throws {
        let nudge = SidebarInsertMotion.nudgeDistance.defaultValue
        let travel = try #require(SidebarInsertMotion.nudge.travel(nudge: nudge))
        let start = SidebarInsertMotion.cap(Self.below.was, toward: Self.below.now, travel: travel)
        #expect(start == Self.below.now.offsetBy(dx: 0, dy: -nudge))
        #expect(Self.below.now.minY - Self.below.was.minY == 28, "the whole distance is a row height")
    }

    /// The new row opens from its height less the nudge, so its bottom meets the row below where that row starts:
    /// no gap opens and the two never overlap.
    @Test func theNewRowsBottomMeetsTheRowBelowsStart() throws {
        let nudge = SidebarInsertMotion.nudgeDistance.defaultValue
        let opening = CGRect(x: Self.newRow.minX, y: Self.newRow.minY, width: Self.newRow.width, height: 0)
        let open = SidebarInsertMotion.nudge.openFrame(opening, target: Self.newRow, nudge: nudge)
        let start = SidebarInsertMotion.cap(Self.below.was, toward: Self.below.now, travel: nudge)
        #expect(open == CGRect(x: 8, y: 8, width: 220, height: 22))
        #expect(open.maxY == start.minY)
    }

    /// A run of new rows (a workspace and the row under it) opens as one slot: each row's start ends where the next starts.
    @Test func aRunOfNewRowsOpensAsOneSlot() {
        let nudge: CGFloat = 6
        let workspace = CGRect(x: 8, y: 8, width: 220, height: 28), tab = CGRect(x: 20, y: 36, width: 208, height: 22)
        let first = SidebarInsertMotion.nudge.openFrame(CGRect(x: 8, y: 8, width: 220, height: 0), target: workspace, nudge: nudge)
        let second = SidebarInsertMotion.nudge.openFrame(CGRect(x: 20, y: 8, width: 208, height: 0), target: tab, nudge: nudge)
        let belowStart = SidebarInsertMotion.cap(CGRect(x: 8, y: 8, width: 220, height: 28),
                                                 toward: CGRect(x: 8, y: 58, width: 220, height: 28), travel: nudge)
        #expect(first.maxY == second.minY)
        #expect(second.maxY == belowStart.minY)
    }

    /// A group line that ends at the moved row starts as close to its end as the row: its top stays put.
    @Test func aLineGrowingWithTheRowsTravelsTheNudgeAtItsEnd() {
        let line = SidebarInsertMotion.cap(CGRect(x: 4, y: 40, width: 2, height: 80), toward: CGRect(x: 4, y: 40, width: 2, height: 108),
                                           travel: 6)
        #expect(line == CGRect(x: 4, y: 40, width: 2, height: 102))
    }

    /// Codex review of #24374 at 618df18: a nudge past the new row's height (40 pt over 28) let a row below that was
    /// drawn farther up (an earlier move in flight) start 40 pt up, above the new row's top. The travel stops at the
    /// new rows' height: the row below starts no higher than the new row's bottom, which opens from zero height.
    @Test func aNudgePastTheRowsHeightTravelsOnlyTheRowsHeight() throws {
        let travel = try #require(SidebarInsertMotion.travel(SidebarInsertMotion.nudge.travel(nudge: 40), within: 28))
        #expect(travel == 28)
        let opening = CGRect(x: 8, y: 8, width: 220, height: 0)
        let open = SidebarInsertMotion.nudge.openFrame(opening, target: Self.newRow, nudge: travel)
        #expect(open == opening)
        let drawnFartherUp = Self.below.now.offsetBy(dx: 0, dy: -40)
        let start = SidebarInsertMotion.cap(drawnFartherUp, toward: Self.below.now, travel: travel)
        #expect(start.minY == open.maxY, "the row below starts at \(start.minY), the new row's bottom is at \(open.maxY)")
        #expect(SidebarInsertMotion.cap(drawnFartherUp, toward: Self.below.now, travel: 40).minY < open.minY,
                "unclamped, the row below would start above the new row")
        #expect(SidebarInsertMotion.travel(nil, within: 28) == nil, "quick and the full spring keep the whole distance")
        #expect(SidebarInsertMotion.travel(6, within: 28) == 6)
    }

    /// The shortest run of new rows: two adjacent rows are one run (50 pt), a lone row another (28 pt).
    @Test func theShortestRunBoundsTheTravel() {
        let tops: [String: CGFloat] = ["ws": 8, "tab": 8, "lone": 100]
        let bottoms: [String: CGFloat] = ["ws": 36, "tab": 58, "lone": 128]
        #expect(SidebarInsertMotion.shortestRun(tops) { bottoms[$0] } == 28)
        #expect(SidebarInsertMotion.shortestRun([String: CGFloat]()) { bottoms[$0] } == .infinity)
    }

    @Test func snapMovesNothingAndTheNewRowFadesInAtItsSlot() {
        #expect(SidebarInsertMotion.snap.travel(nudge: 6) == 0)
        #expect(SidebarInsertMotion.cap(Self.below.was, toward: Self.below.now, travel: 0) == Self.below.now)
        let opening = CGRect(x: 8, y: 8, width: 220, height: 0)
        #expect(SidebarInsertMotion.snap.openFrame(opening, target: Self.newRow, nudge: 6) == Self.newRow)
    }

    @Test func quickAndTheFullSpringKeepTheWholeDistance() {
        let opening = CGRect(x: 8, y: 8, width: 220, height: 0)
        for motion in [SidebarInsertMotion.quick, .spring] {
            #expect(motion.travel(nudge: 6) == nil)
            #expect(motion.openFrame(opening, target: Self.newRow, nudge: 6) == opening)
        }
        #expect(SidebarInsertMotion.spring.token == .move)
        #expect(SidebarInsertMotion.quick.token == .tabOpen)
    }

    /// A row under a header that unfolds it keeps coming out from under the header.
    @Test func anUnfoldingRowKeepsItsStart() {
        let underHeader = CGRect(x: 8, y: 0, width: 220, height: 28)
        #expect(SidebarInsertMotion.nudge.openFrame(underHeader, target: Self.newRow, nudge: 6) == underHeader)
    }

    /// The chosen motion: the rows below are within half a point of their slots in under 100 ms, the spring never
    /// passes its target (critically damped under the default `ui.animations.bounce` none), and it is at rest by 150 ms.
    /// The full spring took a 28 pt row height about 140 ms to come within half a point.
    @Test func theNudgeLandsWithinAHundredMillisecondsWithNoOvershoot() {
        let nudge = SidebarInsertMotion.nudgeDistance.defaultValue
        let spring = MotionPolicy(speed: .fast, reduceMotion: false, bounce: .none, enabledKinds: [.newWorkspace], liveResize: false,
                                  animationsEnabled: true, disabledCategories: []).spring(SidebarInsertMotion.nudge.token)
        #expect(spring.dampingFraction >= 1, "the nudge passes its target")
        let landed = spring.settlingTime(within: 0.5 / nudge)
        #expect(landed < 0.1, "the rows below come within half a point of their slots at \(landed) s")
        #expect(spring.settlingTime(within: 0.002) < 0.15)
        let before = SidebarInsertMotion.spring.token.base.settlingTime(within: 0.5 / 28)
        #expect(landed < before, "the nudge lands at \(landed) s, the full spring at \(before) s")
    }
}
