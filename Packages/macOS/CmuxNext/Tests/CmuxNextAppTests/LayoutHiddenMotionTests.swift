import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// Lucas 2026-10-19: a workspace showed nothing, its pane parked one width off the left edge. Its
/// columns had collapsed to one pane as it was hidden; the pane's spring started from where it
/// showed, the hidden workspace's clock stopped, and showing it again never restarted it. Hiding
/// a layout now ends its motion where it was going.
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

    @Test func hidingTheLayoutEndsItsMotion() {
        let split: SplitNode = .split("h", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p1"))
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(split))], activeScreenID: "s",
                                focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        // The test is the clock: the display link never ticks.
        root.driver.isManual = true

        // p2 closes: p1 springs from the right half over the whole screen.
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(.leaf("p1")))])
        root.syncWithModel()
        let screen = root.screenViews["s"]
        #expect(screen?.hasMotion == true)

        root.isHidden = true
        #expect(screen?.hasMotion == false)
        let frame = screen?.paneFrames["p1"]
        #expect(frame != nil && frame?.rect == frame?.targetRect)
    }
}
