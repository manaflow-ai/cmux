import AppKit
import CmuxNextDesign
import CmuxNextTestSupport
@testable import CmuxNextLayout
import Testing

/// `PaneLayoutCommitTests`, the producers on another thread or in another process (`PaneCommitSurface`): a layout
/// change tells each one its new size in its own turn and waits for its report, for a bounded number of frame ticks. A
/// producer that is late then leaves its pane on its ground, and that ground goes with the report it still owes.
extension PaneLayoutCommitTests {
    /// A producer on another thread or in another process hears its new size in the change's turn, and the change waits
    /// for it: no frame shows the new layout before the producer reported, and the first frame tick after its report
    /// shows it. A pane the change does not resize hears nothing.
    @Test func aChangeWaitsForTheSurfacesItResizesAndShowsWhenTheyReport() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Rest(harness.model.screens, in: screen, style: style)
        let left = try #require(harness.provider.surface(Self.left)), right = try #require(harness.provider.surface(Self.right))

        harness.model.apply(screens: Self.pairSplit(.horizontal))
        let new = Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        #expect(left.asks.count == 1 && right.asks.isEmpty, "only the resized pane's surface hears a size: \(left.asks), \(right.asks)")
        let change = try #require(left.asks.first), was = try #require(old.panes[Self.left]), will = try #require(new.panes[Self.left])
        #expect(abs(change.width - (will.width - was.width)) <= 1.02 && abs(change.height - (will.height - was.height)) <= 1.02,
                "the surface hears how much its pane's size changes: \(change), from \(was) to \(will)")
        #expect(old.isShown(by: Self.shown(screen)), "the change's own turn shows the new layout")

        #expect(harness.root.advanceFrame(PaneMotionBench.frameBudget), "a change that waits asks for no more frames")
        #expect(old.isShown(by: Self.shown(screen)), "a frame tick showed the new layout before its surface reported")
        left.report()
        #expect(old.isShown(by: Self.shown(screen)), "the report showed the new layout outside a frame tick")
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "frames run on after the change showed")
        #expect(new.isShown(by: Self.shown(screen)), "the first frame tick after the report does not show the new layout")
        #expect(screen.lateSurfaceCommits == 0 && harness.root.context.hosts[Self.left]?.showsLateGround == false,
                "a surface that reported in time counts as late")
    }

    /// A producer that does not report: the change shows at its bound, counted in frame ticks (the bound, then the tick
    /// that shows it), never later. That pane shows its own ground, counted as late; every other pane is whole. No frame
    /// tick runs after it. The ground goes when the producer reports, with no frame tick.
    @Test func aSurfaceThatNeverReportsShowsItsPanesGroundAtTheBound() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let style = harness.root.context.style
        let old = Rest(harness.model.screens, in: screen, style: style)
        let left = try #require(harness.provider.surface(Self.left))

        harness.model.apply(screens: Self.pairSplit(.horizontal))
        let new = Rest(harness.model.screens, in: screen, style: style)
        harness.root.syncWithModel()
        // The bound is 3 frame ticks: the count is the test's own, and the product's constant must be that.
        #expect(ScreenContentView.commitBound == 3, "the commit's bound is \(ScreenContentView.commitBound) frame ticks, not 3")
        for tick in 1...3 {
            #expect(harness.root.advanceFrame(PaneMotionBench.frameBudget), "tick \(tick): the change stopped asking for frames inside its bound")
            #expect(old.isShown(by: Self.shown(screen)), "tick \(tick): the new layout showed inside the bound with a surface not ready")
        }
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a frame tick is asked for after the change showed at its bound")
        #expect(new.isShown(by: Self.shown(screen)), "the change did not show at the tick after its bound")
        let hosts = harness.root.context.hosts
        #expect(hosts[Self.left]?.showsLateGround == true, "the late pane does not show its ground")
        #expect(hosts[Self.right]?.showsLateGround == false && hosts[Self.added]?.showsLateGround == false, "a pane that is not late shows ground")
        #expect(screen.lateSurfaceCommits == 1, "the late pane is not counted once: \(screen.lateSurfaceCommits)")
        // The `debug.motion` sample names the late pane apart (`late`); it is one of the panes too.
        let sample = try #require(ScreenContentView.motionSample(screen), "the screen gives no trace sample")
        let ids = { (key: String) in (sample[key] ?? []).compactMap { ($0 as? [Any])?.first as? String } }
        #expect(ids("late") == [Self.left.rawValue], "the trace sample does not name the late pane apart: \(ids("late"))")
        #expect(Set(ids("panes")) == Set([Self.left, Self.right, Self.added].map(\.rawValue)), "the trace sample's panes are not the layout's: \(ids("panes"))")
        for _ in 0..<Self.frames {
            #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "a late surface keeps the frames running")
        }
        #expect(hosts[Self.left]?.showsLateGround == true, "the ground went before the surface reported")
        left.report()
        #expect(hosts[Self.left]?.showsLateGround == false, "the ground stays after the surface reported")
    }

    /// A pane that shows its ground for a late producer, whose producer then goes (its view hides): the next change
    /// that resizes the pane asks no producer and waits for none, and the pane shows its content again with that
    /// change. The ground never stays for a producer that is no longer there.
    @Test func aLatePanesGroundGoesWhenItsSurfaceIsGoneAtTheNextChange() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let left = try #require(harness.provider.surface(Self.left))
        harness.model.apply(screens: Self.pairSplit(.horizontal))
        harness.root.syncWithModel()
        for _ in 0...3 { _ = harness.root.advanceFrame(PaneMotionBench.frameBudget) }
        let host = try #require(harness.root.context.hosts[Self.left])
        try #require(host.showsLateGround, "set-up: the pane whose surface did not report shows no ground")

        // The producer goes: the pane has no surface any more.
        left.isHidden = true
        harness.model.apply(screens: Self.pair)
        harness.root.syncWithModel()
        _ = harness.root.advanceFrame(PaneMotionBench.frameBudget)
        #expect(!host.showsLateGround, "the pane still shows its ground for a surface that is gone")
    }

    /// A late pane whose next resize is taken back before it shows (the close of the pane beside it, and the same split
    /// again in that wait): nothing waits for the pane, and its producer still owes a picture at the size the pane
    /// shows. The ground stays until that report, and goes with it.
    @Test func aLatePanesGroundGoesWithItsSurfacesReportAfterAResizeIsTakenBack() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false, surfaces: true)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let left = try #require(harness.provider.surface(Self.left))
        harness.model.apply(screens: Self.pairSplit(.horizontal))
        harness.root.syncWithModel()
        for _ in 0...3 { _ = harness.root.advanceFrame(PaneMotionBench.frameBudget) }
        let host = try #require(harness.root.context.hosts[Self.left])
        try #require(host.showsLateGround, "set-up: the pane whose surface did not report shows no ground")

        harness.model.apply(screens: Self.pair)
        harness.root.syncWithModel()
        harness.model.apply(screens: Self.pairSplit(.horizontal))
        harness.root.syncWithModel()
        Self.rest(harness)
        #expect(host.showsLateGround, "the ground went before the surface reported at the size its pane shows")
        left.report()
        #expect(!host.showsLateGround, "the ground stays after the surface reported")
    }

    /// The layout asks a pane's content for its producers and walks no view tree for them: a view inside the content
    /// that the content does not name hears no size, and the change does not wait for it.
    @Test func aChangeAsksNoViewThatThePanesContentDoesNotName() throws {
        let harness = Harness(Self.pair, focused: Self.left, holds: false)
        defer { harness.window.closeAfterTest() }
        Self.rest(harness)
        let screen = try #require(harness.screen)
        let content = try #require(harness.provider.contents[Self.left])
        let inner = Surface(frame: content.bounds)
        content.addSubview(inner)

        harness.model.apply(screens: Self.pairSplit(.horizontal))
        let new = Rest(harness.model.screens, in: screen, style: harness.root.context.style)
        harness.root.syncWithModel()
        #expect(inner.asks.isEmpty, "a view inside the content that the content does not name heard a size change: \(inner.asks)")
        #expect(!harness.root.advanceFrame(PaneMotionBench.frameBudget), "the change waits for a view the content does not name")
        #expect(new.isShown(by: Self.shown(screen)), "the first frame tick does not show the new layout")
    }
}
