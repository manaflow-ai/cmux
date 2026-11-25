import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// A workspace showed nothing, its pane parked one width off the left edge: its layout changed as it was
/// hidden, the pane's spring started from where it showed, the hidden workspace's clock stopped, and showing
/// it again never restarted it. Hiding a layout ends its motion where it was going, and shows a layout change
/// that still waited for its frame.
@MainActor
@Suite(.closesItsWindows)
struct LayoutHiddenMotionTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Screens {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1"))),
                                          LayoutScreen(id: "s2", name: "s2", layout: .splits(.leaf("p2")))],
                                activeScreenID: "s1", focusedPane: "p1")
        let root: LayoutRootView
        let window: NSWindow

        init() {
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        func tearDown() { window.closeAfterTest() }
    }

    /// A workspace hidden in the turn of a screen switch, before any frame or layout pass, shows the new screen when
    /// it comes back: the switch is complete in its own turn (no transition is left in flight), so the hide has
    /// nothing to land and the show schedules no frame.
    @Test func showingAfterAScreenSwitchFindsTheNewScreenInPlace() throws {
        let fixture = Screens()
        defer { fixture.tearDown() }
        let root = fixture.root
        let incoming = try #require(root.screenViews["s2"])
        let outgoing = try #require(root.screenViews["s1"])
        fixture.model.selectScreen("s2")
        root.syncWithModel()
        #expect(!incoming.isHidden && incoming.alphaValue == 1 && incoming.frame == root.bounds, "the switch is not complete in its turn")
        #expect(!incoming.hasMotion)
        #expect(outgoing.isHidden)
        #expect(!root.driver.isRunning, "the switch asked for display frames")

        root.isHidden = true
        #expect(!root.driver.isRunning)
        root.isHidden = false
        #expect(root.isLive)
        #expect(!root.driver.isRunning, "the show started a frame for a switch that was complete")
        #expect(!incoming.isHidden)
        #expect(incoming.alphaValue == 1)
        #expect(incoming.frame == root.bounds)
        #expect(outgoing.isHidden)
    }

    @Test func showingAnUnchangedSettledRootLeavesTheDriverIdle() {
        let fixture = Screens()
        defer { fixture.tearDown() }
        let root = fixture.root
        let moving = root.screenViews.values.contains(where: \.hasMotion)
        #expect(!moving)
        #expect(!root.driver.isRunning)
        root.isHidden = true
        root.isHidden = false
        #expect(root.isLive)
        #expect(root.driver.isAttached)
        #expect(!root.driver.isRunning)
    }

    /// A split with p2 left of p1, in a window, with the test as the clock.
    static func pair() -> (model: LayoutModel, root: LayoutRootView, window: NSWindow) {
        let split: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p1"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))], activeScreenID: "s",
                                focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        // The test is the clock: the display link never ticks.
        root.driver.isManual = true
        return (model, root, window)
    }

    @Test func hidingTheLayoutEndsItsMotion() {
        let (model, root, window) = Self.pair()
        defer { window.closeAfterTest() }

        // The split's ratio changes (another client moved its divider): both panes spring to their new widths.
        let moved: SplitNode = .split("h", axis: .horizontal, ratio: 0.3, a: .leaf("p2"), b: .leaf("p1"))
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(moved))])
        root.syncWithModel()
        let screen = root.screenViews["s"]
        #expect(screen?.hasMotion == true)

        root.isHidden = true
        #expect(screen?.hasMotion == false)
        let frame = screen?.paneFrames["p1"]
        #expect(frame != nil && frame?.rect == frame?.targetRect)
    }

    /// A close is one commit that waits for its frame tick. A layout hidden before that tick shows the close as it
    /// hides: the pane that stays has its place and the closed pane is hidden, so the layout shows whole when it
    /// comes back.
    @Test func hidingTheLayoutShowsACloseThatWaitedForItsFrame() throws {
        let (model, root, window) = Self.pair()
        defer { window.closeAfterTest() }
        let kept = try #require(root.context.hosts["p1"]), closed = try #require(root.context.hosts["p2"])
        let before = kept.frame

        // p2 closes: p1 gets the whole screen.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))])
        root.syncWithModel()
        let screen = try #require(root.screenViews["s"])
        #expect(!screen.hasMotion, "a close put a pane on a spring")
        #expect(kept.frame == before && !closed.isHidden, "the close showed before its frame tick: \(kept.frame)")

        root.isHidden = true
        #expect(closed.isHidden, "the closed pane still shows in the layout that hid")
        #expect(kept.frame.width > before.width && kept.frame == screen.displayedFrame(of: "p1"),
                "the pane that stays is not at its place in the layout that hid: \(kept.frame)")
        #expect(!screen.hasMotion)
    }
}
