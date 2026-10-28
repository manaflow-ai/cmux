import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextWakeups
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

    /// A close with the default choice is the split's inverse: the plan sets every pane and divider at rest.
    @Test func aCloseIsSetAtRestByDefault() throws {
        let before = Plan.splits(Plan.stacked(Plan.side(.leaf("p1"), .leaf("p2")), .leaf("p3"), id: "a"))
        let after = Plan.splits(Plan.stacked(.leaf("p1"), .leaf("p3"), id: "a"))
        let plan = PaneMotionPlan.build(from: before, to: after)
        #expect(plan.kind == .close)
        for (pane, change) in plan.panes { #expect(change.from == change.to, "\(pane) springs from \(change.from) to \(change.to)") }
        for (divider, change) in plan.dividers { #expect(change.from == change.to, "\(divider) springs") }
    }

    // MARK: The content

    /// Records each pane a split fades in (`paneArrived`), so its content fades in when it first draws.
    final class ArrivalPanes: LayoutPaneContentProvider {
        var arrived: [PaneID] = []
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
        func paneArrived(_ pane: PaneID) { arrived.append(pane) }
    }

    /// The key's turn tells the provider which pane arrived, once, so its content (a terminal before its shell's first
    /// output) can fade in when it draws instead of popping in after the pane; Reduce Motion tells it nothing.
    @Test(arguments: [false, true])
    func theKeysTurnTellsTheProviderWhichPaneArrived(reduceMotion: Bool) throws {
        let panes = ArrivalPanes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(SplitSpringMotionTests.pair))],
                                activeScreenID: "s", focusedPane: "p1")
        model.splitSizingOverride = .even
        let root = LayoutRootView(model: model, contentProvider: panes, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
        root.context.reduceMotionOverride = reduceMotion
        root.context.splitArrival = { .fade }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        _ = model.showSplitSizing(model.splitSizingChanges(splitting: "p2", axis: .horizontal))
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(SplitSpringMotionTests.pairSplit))])
        root.syncWithModel()
        #expect(panes.arrived == (reduceMotion ? [] : ["p3"]), "arrived: \(panes.arrived)")
        // The daemon's echo of the same layout adds no pane: nothing arrives again.
        root.syncWithModel()
        #expect(panes.arrived.count <= 1)
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
