import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import QuartzCore
import Testing

/// Leo 2026-10-27: "all the text gets compressed into that workspace zone, and you get, like,
/// overlapping text for a split second. So I feel like you should just fade it a bit faster or a bit
/// earlier in the movement, so that it looks like, you know, it, like, tucks under rather than it
/// tucks over." A folding tab line is gone early in its slide and draws behind the workspace row; an
/// opening one shows only late. Workspace rows keep the shared fade.
@MainActor @Suite(.serialized)
struct SidebarTabTuckTests {
    /// Motion pinned on, so the host's Reduce Motion or a saved switch cannot turn the fades off.
    private static func motionOn() -> () -> Void {
        let design = DesignSettings.shared
        let (enabled, disabled) = (design.animationsEnabled, design.disabledAnimationCategories)
        design.animationsEnabled = true
        design.disabledAnimationCategories = []
        Motion.reduceMotionOverride = false
        return {
            design.animationsEnabled = enabled
            design.disabledAnimationCategories = disabled
            Motion.reduceMotionOverride = nil
        }
    }

    private static func line(_ tab: String) -> SidebarRowView {
        _ = NSApplication.shared
        return SidebarTabRowView(key: .tab(WorkspaceID("ws-tuck"), TabID(tab)))
    }

    private static func fade(_ view: SidebarRowView) -> CAKeyframeAnimation? {
        view.layer?.animation(forKey: RowMotion.tuckKey) as? CAKeyframeAnimation
    }

    private static func values(_ fade: CAKeyframeAnimation) -> [Double]? {
        (fade.values as? [NSNumber])?.map(\.doubleValue)
    }

    private static func times(_ fade: CAKeyframeAnimation) -> [Double] { (fade.keyTimes ?? []).map(\.doubleValue) }

    /// The first tab line, one row under its workspace's: folding it slides up into the row's slot, opening it
    /// slides down out of it.
    @Test func aFoldingLineFadesEarlyBehindTheRow() throws {
        let restore = Self.motionOn()
        defer { restore() }
        try #require(Motion.sidebar.animatesFades, "fades are off here")
        let folding = Self.line("t1"), opening = Self.line("t2")
        let header = SidebarRowView(key: .workspace(WorkspaceID("ws-tuck")))
        let row = NSRect(x: 0, y: 0, width: 200, height: 24), slot = row.offsetBy(dx: 0, dy: 24)
        folding.frame = slot
        opening.frame = row
        opening.alphaValue = 0 // a line opens from under the row at 0 (`SidebarListView` places it so)
        let tucked = RowMotion.tuck(appearing: [(opening, slot)], leaving: [(folding, row), (header, row)])

        #expect(tucked == [ObjectIdentifier(folding), ObjectIdentifier(opening)], "the workspace row left the shared fade")
        let out = try #require(Self.fade(folding))
        #expect(Self.values(out) == [1, 0, 0])
        let gone = Self.times(out)[1]
        #expect(gone > 0 && gone <= RowMotion.tuckFraction, "the folding line is gone at \(gone) of the move")
        // Half of the line is under the row no sooner than it is gone.
        let spring = Motion.sidebar.spring(.move), settle = spring.settlingTime(within: 0.03)
        #expect(RowMotion.time(toCover: 0.5, spring) / settle >= gone - 0.01)
        #expect(out.duration > 0)
        #expect(folding.layer?.zPosition == -1, "a folding line draws over the workspace row")
        #expect(folding.alphaValue == 0)

        let into = try #require(Self.fade(opening))
        #expect(Self.values(into) == [0, 0, 1, 1])
        let shows = Self.times(into)[1]
        // It shows only once 90% of it is out from under the row.
        #expect(shows >= RowMotion.time(toCover: 0.9, spring) / settle - 0.01, "the opening line shows at \(shows), still under the row")
        #expect(opening.alphaValue == 1)
        #expect(Self.fade(header) == nil)

        RowMotion.untuck([folding, opening, header])
        #expect(Self.fade(folding) == nil && Self.fade(opening) == nil)
        #expect(folding.layer?.zPosition == 0 && opening.layer?.zPosition == 0)
    }

    /// A line further down travels further, so it fades by `tuckFraction` at the latest and shows from it.
    @Test func farLinesKeepTheBounds() {
        let spring = Motion.sidebar.spring(.move), settle = spring.settlingTime(within: 0.03)
        let out = RowMotion.fadeTimes(opening: false, travel: 240, height: 24, header: 24, spring: spring, settle: settle)
        let into = RowMotion.fadeTimes(opening: true, travel: 240, height: 24, header: 24, spring: spring, settle: settle)
        #expect(out[1] <= RowMotion.tuckFraction && into[1] >= RowMotion.tuckFraction)
        #expect(zip(into, into.dropFirst()).allSatisfy { $0 <= $1 } && into.last == 1)
    }

    /// A tab line parked mid-tuck and reused draws in the rows' order again, its tuck gone (Codex review).
    @Test func aReusedLineDrawsInOrder() throws {
        let restore = Self.motionOn()
        defer { restore() }
        try #require(Motion.sidebar.animatesFades, "fades are off here")
        let line = Self.line("t4")
        _ = RowMotion.tuck(appearing: [], leaving: [(line, NSRect(x: 0, y: 0, width: 200, height: 24))])
        try #require(line.layer?.zPosition == -1)
        line.prepareForReuse(key: .tab(WorkspaceID("ws-tuck"), TabID("t5")))
        #expect(line.layer?.zPosition == 0 && Self.fade(line) == nil)
    }

    /// Under a taller workspace row (expanded, or with a status line) a folding line is gone sooner and an opening
    /// line shows later than under a one-line row (Codex review).
    @Test func aTallerRowTucksSoonerAndShowsLater() {
        let spring = Motion.sidebar.spring(.move), settle = spring.settlingTime(within: 0.03)
        let line: CGFloat = 24, gap: CGFloat = 2
        for header: CGFloat in [24, 44, 64] {
            let travel = header + gap
            let out = RowMotion.fadeTimes(opening: false, travel: travel, height: line, header: header, spring: spring, settle: settle)
            let into = RowMotion.fadeTimes(opening: true, travel: travel, height: line, header: header, spring: spring, settle: settle)
            // Gone no later than half the line is under the row; shown no sooner than 90% of it is out.
            let halfUnder = RowMotion.time(toCover: Double((travel - header + line / 2) / travel), spring) / settle
            let mostlyOut = RowMotion.time(toCover: Double((header - line / 10) / travel), spring) / settle
            #expect(out[1] <= max(0.1, halfUnder) + 0.01, "header \(header): gone at \(out[1]), half under at \(halfUnder)")
            #expect(into[1] >= min(0.98, mostlyOut) - 0.001, "header \(header): shows at \(into[1]), out at \(mostlyOut)")
        }
    }

    /// A line its group header folds (its fold y is not its workspace row's) keeps the shared fade (Codex review).
    @Test func aGroupFoldDoesNotTuck() throws {
        let restore = Self.motionOn()
        defer { restore() }
        try #require(Motion.sidebar.animatesFades, "fades are off here")
        let line = Self.line("t9")
        let groupHeader = NSRect(x: 0, y: 0, width: 200, height: 24), workspace = NSRect(x: 0, y: 26, width: 200, height: 24)
        line.frame = workspace.offsetBy(dx: 0, dy: 26)
        let tucked = RowMotion.tuck(appearing: [], leaving: [(line, groupHeader)], header: { _ in workspace })
        #expect(tucked.isEmpty && Self.fade(line) == nil)
        let own = RowMotion.tuck(appearing: [], leaving: [(line, workspace)], header: { _ in workspace })
        #expect(own == [ObjectIdentifier(line)])
    }

    /// A group opening around a workspace starts the workspace and its tabs at the group header's y: the
    /// workspace moves, so it covers no line and the tabs keep the shared fade (Codex review).
    @Test func aMovingWorkspaceCoversNothing() {
        let line = Self.line("t8")
        let row = SidebarRowView(key: .workspace(WorkspaceID("ws-tuck")))
        row.frame = NSRect(x: 0, y: 0, width: 200, height: 24)
        let rows: [SidebarRowKey: SidebarRowView] = [.workspace(WorkspaceID("ws-tuck")): row]
        #expect(RowMotion.cover(of: line, rows: rows, moving: []) == row.frame)
        #expect(RowMotion.cover(of: line, rows: rows, moving: [ObjectIdentifier(row)]) == nil)
        #expect(RowMotion.cover(of: row, rows: rows, moving: []) == nil)
    }

    /// A new tab opening its own slot (zero height there) and a closed one closing its slot keep the shared fade:
    /// nothing is under a row (Codex review).
    @Test func aSlotOpenDoesNotTuck() throws {
        let restore = Self.motionOn()
        defer { restore() }
        try #require(Motion.sidebar.animatesFades, "fades are off here")
        let new = Self.line("t6"), closed = Self.line("t7")
        new.frame = NSRect(x: 0, y: 48, width: 200, height: 0)
        closed.frame = NSRect(x: 0, y: 72, width: 200, height: 24)
        let tucked = RowMotion.tuck(appearing: [(new, NSRect(x: 0, y: 48, width: 200, height: 24))],
                                    leaving: [(closed, NSRect(x: 0, y: 72, width: 200, height: 0))])
        #expect(tucked.isEmpty)
        #expect(Self.fade(new) == nil && Self.fade(closed) == nil)
        #expect(new.layer?.zPosition == 0 && closed.layer?.zPosition == 0)
    }

    /// A fold reversed mid-move: the first move's end leaves the second move's tuck on the line (Codex review).
    @Test func anOlderMoveLeavesTheNewerTuck() throws {
        let restore = Self.motionOn()
        defer { restore() }
        try #require(Motion.sidebar.animatesFades, "fades are off here")
        let line = Self.line("t8")
        let row = NSRect(x: 0, y: 0, width: 200, height: 24), slot = row.offsetBy(dx: 0, dy: 24)
        line.frame = slot
        _ = RowMotion.tuck(appearing: [], leaving: [(line, row)], move: 1)
        line.frame = row
        _ = RowMotion.tuck(appearing: [(line, slot)], leaving: [], move: 2)
        RowMotion.untuck([line], move: 1)
        #expect(Self.fade(line) != nil && line.layer?.zPosition == -1, "the first move's end took the second move's tuck")
        // The turn starts from what the line showed (it had no presentation yet, so its model alpha, 0), not from 1.
        #expect(Self.values(try #require(Self.fade(line)))?.first == 0, "the turned-around fade starts from full opacity")
        RowMotion.untuck([line], move: 2)
        #expect(Self.fade(line) == nil && line.layer?.zPosition == 0)
    }

    /// With fades off nothing tucks: the shared fade (itself off then) sets the end alpha.
    @Test func nothingTucksWithFadesOff() {
        let design = DesignSettings.shared
        let enabled = design.animationsEnabled
        design.animationsEnabled = false
        defer { design.animationsEnabled = enabled }
        let line = Self.line("t3")
        let tucked = RowMotion.tuck(appearing: [], leaving: [(line, NSRect(x: 0, y: 0, width: 200, height: 24))])
        #expect(tucked.isEmpty)
        #expect(Self.fade(line) == nil)
        #expect(line.layer?.zPosition == 0)
    }
}
