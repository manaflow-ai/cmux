import AppKit
@testable import CmuxNextApp
import CmuxNextFeatures
import CmuxNextHibernation
import CmuxNextSidebar
import CmuxNextTabs
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// p03-rendering-096 (plans/cmux-next/chrome-parity/p03-rendering.md R6): the switch hides the outgoing
/// workspace in its turn and leaves it in the window, so a switch back to a recently hidden workspace
/// makes 0 `viewDidMoveToWindow` calls. Taking hidden workspaces out of the window after a grace is a
/// measured arm (feature `hiddenWorkspaceDetachAfterGrace`, default off; its policy:
/// HiddenWorkspaceDetachTests).
@MainActor @Suite(.serialized) struct HiddenWorkspaceStaysInWindowTests {
    /// Counts the times it enters and leaves a window, as a terminal or a page deep in a workspace would.
    final class WindowMoves: NSView {
        private(set) var moves = 0
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moves += 1
        }
    }

    /// The detach's deadline, fired by hand.
    final class FakeDeadline: HiddenWorkspaceDetachDeadline {
        private(set) var delay: Duration?
        private var action: (@MainActor () -> Void)?
        func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) {
            self.delay = delay
            self.action = action
        }

        func cancel() {
            delay = nil
            action = nil
        }

        func fire() {
            let pending = action
            delay = nil
            action = nil
            pending?()
        }
    }

    final class Clock {
        var now = ContinuousClock.now
    }

    private func makeRoot() -> (NSWindow, WindowRootView) {
        _ = NSApplication.shared
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        settle(root)
        return (window, root)
    }

    private func settle(_ root: WindowRootView) {
        for _ in 0..<4 { root.layoutSubtreeIfNeeded() }
    }

    /// A workspace whose layout holds one probe, nested as a pane's content is.
    private func makeWorkspace() -> (WorkspaceContentView, WindowMoves) {
        let layout = NSView(), pane = NSView(), probe = WindowMoves()
        pane.addSubview(probe)
        layout.addSubview(pane)
        return (WorkspaceContentView(layoutView: layout, bar: TabStripView.testing(model: TabStripModel())), probe)
    }

    private func show(_ view: WorkspaceContentView, in root: WindowRootView) {
        root.show(view)
        settle(root)
    }

    @Test func switchingBackToARecentlyHiddenWorkspaceMovesNoViewIntoTheWindow() {
        let (window, root) = makeRoot()
        defer { window.close() }
        let (a, probeA) = makeWorkspace(), (b, probeB) = makeWorkspace(), (c, probeC) = makeWorkspace()
        for view in [a, b, c] { show(view, in: root) }
        let entered = [probeA.moves, probeB.moves, probeC.moves]
        #expect(entered == [1, 1, 1], "each workspace enters the window once, at its first show")
        #expect(a.isHidden && b.isHidden && !c.isHidden, "the outgoing workspace hides in the switch's turn")

        for view in [a, c, b, a, b, c] {
            show(view, in: root)
            #expect(!view.isHidden && view.window === window)
        }
        let moved = zip([probeA.moves, probeB.moves, probeC.moves], entered).map { $0 - $1 }
        #expect(moved == [0, 0, 0], "switches back to hidden workspaces moved views into or out of the window: \(moved)")
        #expect([a, b].allSatisfy { $0.isHidden && $0.superview === root.contentHost }, "hidden workspaces stay in the main pane")
    }

    @Test func hidingOnlyIsTheDefault() {
        let feature = Feature.hiddenWorkspaceDetachAfterGrace
        for channel in [Feature.Channel.dev, .nightly, .release] {
            #expect(!FeatureList(registry: FeatureRegistry(), channel: channel).isEnabled(feature), "\(channel)")
        }
        #expect(feature.durationParam("grace") == .seconds(30))
    }

    @Test func withTheDetachArmTheMainPaneLetsAWorkspaceGoAfterTheGraceAndTakesItBackWhenShown() {
        let (window, root) = makeRoot()
        defer { window.close() }
        let deadline = FakeDeadline(), clock = Clock()
        let detach = HiddenWorkspaceDetach(grace: .seconds(30), deadline: deadline, now: { clock.now })
        root.contentHost.hiddenDetach = detach
        let (a, probeA) = makeWorkspace(), (b, _) = makeWorkspace()
        show(a, in: root)
        show(b, in: root)
        #expect(deadline.delay == .seconds(30), "A's grace starts when it hides")
        clock.now += .seconds(29)
        show(a, in: root)
        #expect(probeA.moves == 1, "A came back within the grace without leaving the window")
        #expect(detach.pendingCount == 1, "only B, hidden now, waits")

        clock.now += .seconds(30)
        deadline.fire()
        #expect(b.superview == nil && detach.detachedCount == 1, "B hidden past its grace left the main pane")
        #expect(a.superview === root.contentHost && !a.isHidden, "the shown workspace never leaves")

        show(b, in: root)
        #expect(b.superview === root.contentHost && b.window === window && !b.isHidden, "a detached workspace joins the window when shown")
        #expect(a.isHidden && a.superview === root.contentHost && detach.pendingCount == 1, "A, hidden now, waits for its own grace")
    }

    /// The side-by-side view (`WindowController.arrangeOnScreen`, `clearArrangement`) shows and hides a workspace
    /// by its `isHidden`, not through `WindowRootView.show`: each hide restarts the grace and each show ends it,
    /// so a workspace never leaves within the grace of its latest hide.
    @Test func aWorkspaceHiddenAgainBesideTheShownOneIsMeasuredFromItsLatestHide() {
        let (window, root) = makeRoot()
        defer { window.close() }
        let deadline = FakeDeadline(), clock = Clock()
        let detach = HiddenWorkspaceDetach(grace: .seconds(30), deadline: deadline, now: { clock.now })
        root.contentHost.hiddenDetach = detach
        let (a, _) = makeWorkspace(), (b, _) = makeWorkspace()
        show(a, in: root)
        show(b, in: root)
        #expect(detach.pendingCount == 1 && deadline.delay == .seconds(30), "A's grace starts when the switch hides it")

        clock.now += .seconds(10)
        a.isHidden = false  // A comes on screen beside B
        #expect(detach.pendingCount == 0 && deadline.delay == nil, "a workspace on screen waits for no grace")
        clock.now += .seconds(15)
        a.isHidden = true  // A leaves the set at 25 s
        #expect(detach.pendingCount == 1 && deadline.delay == .seconds(30), "A's grace starts again at its latest hide")

        clock.now += .seconds(5)
        deadline.fire()  // 30 s after the first hide, 5 s after the latest
        #expect(detach.detachedCount == 0 && a.superview === root.contentHost && a.isHidden, "A left 5 s after its latest hide")
        #expect(deadline.delay == .seconds(25), "the deadline aims at the end of A's latest grace")

        clock.now += .seconds(25)
        deadline.fire()
        #expect(detach.detachedCount == 1 && a.superview == nil, "A hidden for its whole grace leaves the main pane")
        #expect(b.superview === root.contentHost && !b.isHidden)
    }

    /// The other order: the deadline fires while the workspace shows beside the shown one, then a direct hide
    /// starts its grace, and it leaves once that grace ends.
    @Test func aWorkspaceHiddenDirectlyAfterTheDeadlineSkippedItStillLeavesAfterItsGrace() {
        let (window, root) = makeRoot()
        defer { window.close() }
        let deadline = FakeDeadline(), clock = Clock()
        let detach = HiddenWorkspaceDetach(grace: .seconds(30), deadline: deadline, now: { clock.now })
        root.contentHost.hiddenDetach = detach
        let (a, _) = makeWorkspace(), (b, _) = makeWorkspace()
        show(a, in: root)
        show(b, in: root)
        clock.now += .seconds(10)
        a.isHidden = false
        clock.now += .seconds(20)
        deadline.fire()
        #expect(detach.detachedCount == 0 && a.superview === root.contentHost && !a.isHidden, "a workspace on screen never leaves")

        a.isHidden = true
        #expect(detach.pendingCount == 1 && deadline.delay == .seconds(30), "a direct hide is measured")
        clock.now += .seconds(30)
        deadline.fire()
        #expect(detach.detachedCount == 1 && a.superview == nil)
    }
}
