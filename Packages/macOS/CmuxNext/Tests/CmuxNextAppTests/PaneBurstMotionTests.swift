import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import Testing

/// A burst of presses (Lawrence 2026-10-24: spamming Cmd-D / Cmd-W lags and does not interrupt well): a split
/// or close that lands while a spring runs retargets from what shows, with no jump and no extra step.
@MainActor
@Suite struct PaneBurstMotionTests {
    /// Four columns side by side; `closed` leaves the named columns out.
    static func row(_ count: Int, without closed: Set<Int> = []) -> [LayoutScreen] {
        let kept = (0..<count).filter { !closed.contains($0) }
        let columns = kept.map { PaneMotionBench.column($0, rows: 1, width: 1.0 / Double(kept.count)) }
        return [LayoutScreen(id: "s", name: "s", layout: .columns(columns))]
    }

    /// M4 (PL-burst): a divider released with a velocity seeds only the frames its layout change moves; a pane
    /// already springing for another reason (a column closing elsewhere) keeps its own velocity.
    @Test func aDividerReleaseSeedsOnlyTheFramesItMoves() throws {
        var frames: [PaneID: AnimatedFrame] = [:]
        var moving = AnimatedFrame(CGRect(x: 0, y: 0, width: 100, height: 100))
        moving.setTarget(CGRect(x: 0, y: 0, width: 300, height: 100))
        moving.width.velocity = 777
        frames[PaneID("unrelated")] = moving
        var released = AnimatedFrame(CGRect(x: 0, y: 0, width: 200, height: 100))
        released.setTarget(CGRect(x: 0, y: 0, width: 260, height: 100))
        frames[PaneID("beside")] = released
        var divider = AnimatedFrame(CGRect(x: 200, y: 0, width: 4, height: 100))
        divider.setTarget(CGRect(x: 260, y: 0, width: 4, height: 100))
        var dividers: [DividerHandleView.Kind: AnimatedFrame] = [.split(SplitID("d")): divider]
        SplitMotion.seed(velocity: 600, along: .horizontal, divider: divider, panes: &frames, dividers: &dividers,
                         moved: [PaneID("beside")])
        #expect(frames[PaneID("unrelated")]?.width.velocity == 777, "the release reset a spring it does not move")
        #expect((frames[PaneID("beside")]?.width.velocity ?? 0) > 0, "the pane beside the divider was not seeded")
    }

    /// M8 (PL-burst, suspected): an animated width change of a column left of the camera (a width preset, an
    /// equalize) moves the strip; no pane may jump in the change's own turn, and every frame moves each pane by a
    /// small step (no frame covers more than half of a pane's whole travel).
    @Test func anAnimatedWidthChangeMovesTheStripWithoutAJump() async throws {
        let columns = (0..<5).map { PaneMotionBench.column($0, rows: 1, width: 0.5) }
        let harness = PaneMotionBench.Harness([LayoutScreen(id: "s", name: "s", layout: .columns(columns))], focused: PaneID("p3-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        let hosts = screen.subviews.compactMap { $0 as? PaneHostView }
        var shown = Dictionary(uniqueKeysWithValues: hosts.map { ($0.pane, $0.frame.minX) })
        harness.model.setColumnWidth(ColumnID("c0"), width: 0.8, transaction: .make(), phase: .ended)
        harness.root.syncWithModel()
        for host in hosts {
            #expect(abs(host.frame.minX - (shown[host.pane] ?? 0)) < 0.5, "\(host.pane) jumped in the change's turn")
        }
        var steps: [PaneID: [CGFloat]] = [:]
        for _ in 0..<240 {
            let moving = await harness.frame().moving
            for host in hosts {
                steps[host.pane, default: []].append(host.frame.minX - (shown[host.pane] ?? 0))
                shown[host.pane] = host.frame.minX
            }
            if !moving { break }
        }
        for (pane, moves) in steps {
            let travel = moves.reduce(0) { $0 + abs($1) }
            guard travel > 1 else { continue }
            let largest = moves.map(abs).max() ?? 0
            #expect(largest <= travel / 2, "\(pane) moved \(largest) of its \(travel) pt travel in one frame")
        }
    }
}
