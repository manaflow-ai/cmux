import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// Cmd-D fades the new pane in (Lawrence 2026-10-27: "Making a new split needs a more subtle animation for the
/// split that is coming in (just an opacity fade maybe)"; plans/cmux-next/motion-first-principles.md). The split is
/// laid out once, in the key's turn, at its final layout: the new pane at its rest frame and every pane beside it
/// at its new size, with no frame or position motion. Only the new pane's opacity animates, on its layer.
@MainActor
struct SplitFadeMotionTests {
    typealias Plan = PaneMotionPlanTests

    // MARK: The plan

    /// The plan of Cmd-D on one pane: the new pane rests where it lands from its first frame (no sliver growing in
    /// from the old edge), and the split pane and the new divider are set at their rests (no spring).
    @Test func aSplitsNewPaneHasNoFrameMotionAndTheRestIsSetAtRest() throws {
        let before = Plan.splits(.leaf("p1")), after = Plan.splits(Plan.side(.leaf("p1"), .leaf("p2")))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .split)
        let added = try #require(plan.panes["p2"])
        #expect(added.presence == .appears)
        #expect(added.from == added.to, "the new pane moves: \(added.from) to \(added.to)")
        #expect(added.chrome == nil, "the new pane's chrome resizes on a spring")
        for (pane, change) in plan.panes where pane != "p2" {
            #expect(change.from == change.to, "\(pane) springs from \(change.from) to \(change.to)")
        }
        for (divider, change) in plan.dividers {
            #expect(change.from == change.to, "\(divider) springs from \(change.from) to \(change.to)")
        }
    }

    /// An even split (`layout.splitSizing`) of p2 in p1 | p2: the whole chain takes its new sizes in the one layout
    /// pass, not on a spring.
    @Test func anEvenSplitSetsTheWholeChainAtRest() throws {
        let pair = Plan.side(.leaf("p1"), .leaf("p2"), id: "r")
        let split = SplitNode.split("r", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"),
                                    b: .split("n", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3")))
        let plan = PaneMotionPlan.build(from: Plan.splits(pair), to: Plan.splits(split))
        #expect(plan.kind == .split)
        for (pane, change) in plan.panes {
            #expect(change.from == change.to, "\(pane) springs from \(change.from) to \(change.to)")
        }
        for (divider, change) in plan.dividers {
            #expect(change.from == change.to, "\(divider) springs from \(change.from) to \(change.to)")
        }
    }

    /// A content handoff (the added pane takes over what p1 showed): p1, which shows the new content, fades in at its
    /// rest; nothing slides in from the screen edge.
    @Test func aHandoffFadesTheGiverInAtItsRest() throws {
        let before = Plan.splits(.leaf("p1")), after = Plan.splits(Plan.side(.leaf("p1"), .leaf("p2")))
        let plan = PaneMotionPlan.build(from: before, to: after, handoff: "p1")
        #expect(plan.fadesIn == ["p1"])
        for (pane, change) in plan.panes {
            #expect(change.from == change.to, "\(pane) springs from \(change.from) to \(change.to)")
        }
    }

    /// A new docked column is a rare spatial change: it still grows in from its screen edge, and fades nothing.
    @Test func aNewDockColumnStillGrowsFromItsEdge() throws {
        let plan = PaneMotionPlan.build(from: Plan.geometry(DockArrivalRenderMotionTests.strip),
                                        to: Plan.geometry(DockArrivalRenderMotionTests.docked))
        #expect(plan.fadesIn.isEmpty, "the dock column fades: \(plan.fadesIn)")
        let dock = try #require(plan.panes["chat"])
        #expect(dock.from != dock.to, "the dock column does not grow in")
    }

    // MARK: The window

    /// Cmd-D in a window: the key's turn lays every pane of the chain out at its rest (one layout pass), and no
    /// display frame moves a pane after it (the CPU steps nothing).
    @Test func theKeysTurnLaysTheSplitOutAtRestAndNoFrameMovesAPane() throws {
        let screen = SplitSpringMotionTests.Screen(SplitSpringMotionTests.pair)
        _ = SplitSpringMotionTests.splitPair(screen)
        for pane in SplitSpringMotionTests.chain {
            let rect = try #require(screen.rect(pane)), target = try #require(screen.target(pane))
            #expect(rect == target, "\(pane) shows at \(rect), not at its rest \(target)")
        }
        let shown = try #require(screen.screen?.paneFrames["p3"]?.rect)
        #expect(!screen.step(), "the split asked for display frames")
        #expect(screen.rect("p3") == shown)
        let widths = try SplitSpringMotionTests.chain.map { try #require(screen.rect($0)).width }
        #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.5, "not even in the key's turn: \(widths)")
    }
}
