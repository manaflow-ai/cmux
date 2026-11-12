import AppKit
@testable import CmuxNextLayout
import CmuxNextTestSupport
import CmuxNextWakeups
import Testing

/// A workspace's hidden screens mount when they first show or at idle, not in the frame that shows the workspace
/// (Leo 2026-11-04: the visible window comes first, off-screen work is deferred). A screen mounted late shows as
/// one mounted with the shown screen did: hidden at its place, then slid in by the switch, with no pop-in.
@MainActor
@Suite(.closesItsWindows)
struct HiddenScreenDeferredMountTests {
    final class Panes: LayoutPaneContentProvider {
        var made: [PaneID] = []
        func makeContentView(for pane: PaneID) -> NSView {
            made.append(pane)
            return NSView()
        }
    }

    /// Screen s1 shown, s2 hidden with two panes, in a window, its root deferring hidden screens; the test is the clock.
    final class Layout {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1"))),
                                          LayoutScreen(id: "s2", name: "s2", layout: .splits(
                                              .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p2"), b: .leaf("p3"))))],
                                activeScreenID: "s1", focusedPane: "p1")
        let root: LayoutRootView
        let window: NSWindow

        init() {
            root = LayoutRootView(model: model, contentProvider: provider, hiddenScreens: FrameBatchQueue(owner: "test.hiddenScreens"))
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.syncWithModel()
        }
    }

    @Test func theShownScreenMountsAloneAndAHiddenOneWaits() {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        #expect(layout.provider.made == ["p1"])
        #expect(layout.root.screenViews["s2"] == nil)
        #expect(layout.root.deferredScreens == ["s2"])
    }

    @Test func aWaitingScreenSlidesInOnItsFirstShow() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let root = layout.root
        layout.model.selectScreen("s2")
        root.syncWithModel()
        let incoming = try #require(root.screenViews["s2"], "the shown screen was not made")
        #expect(Set(layout.provider.made) == ["p1", "p2", "p3"])
        #expect(root.deferredScreens.isEmpty)
        // It starts where a screen made with the shown one starts a switch: clear, one step to its side.
        #expect(!incoming.isHidden)
        #expect(incoming.alphaValue == 0)
        #expect(incoming.frame.origin.x > root.bounds.minX)
        #expect(root.driver.isRunning)
        let frames = try #require(incoming.paneFrames.values.first)
        #expect(frames.rect == frames.targetRect, "its panes spring in a screen that was hidden")
        let scheduler = FrameScheduler.forWindow(layout.window)
        for tick in 0..<240 {
            if !root.driver.isRunning { break }
            scheduler.frameDidFire(timestamp: Double(tick) / 120)
        }
        #expect(incoming.alphaValue == 1)
        #expect(incoming.frame.origin == root.bounds.origin)
        #expect(root.screenViews["s1"]?.isHidden == true)
    }

    @Test func anIdleMountMakesTheScreenHiddenAtRest() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let root = layout.root
        #expect(root.mountDeferredScreen())
        let hidden = try #require(root.screenViews["s2"])
        #expect(hidden.isHidden)
        #expect(Set(layout.provider.made) == ["p1", "p2", "p3"])
        #expect(hidden.paneFrames.count == 2 && hidden.paneFrames.values.allSatisfy { $0.rect == $0.targetRect })
        #expect(!hidden.hasMotion)
        #expect(root.deferredScreens.isEmpty)
        #expect(!root.mountDeferredScreen(), "a second mount found a screen to make")
        #expect(layout.provider.made.count == 3)
    }

    @Test func aPaneMovedToAWaitingScreenMovesInsideTheWindow() throws {
        let layout = Layout()
        defer { layout.window.closeAfterTest() }
        let root = layout.root
        let host = try #require(root.context.hosts["p1"])
        layout.model.apply(screens: [
            LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p4"))),
            LayoutScreen(id: "s2", name: "s2", layout: .splits(
                .split("b", axis: .horizontal, ratio: 0.5, a: .leaf("p2"),
                       b: .split("c", axis: .horizontal, ratio: 0.5, a: .leaf("p3"), b: .leaf("p1"))))),
        ])
        root.syncWithModel()
        let screen = try #require(root.screenViews["s2"], "the screen that took the shown pane was not made")
        #expect(root.context.hosts["p1"] === host, "the moved pane was made again")
        #expect(host.isDescendant(of: screen))
        #expect(layout.provider.made.filter { $0 == "p1" }.count == 1)
    }
}
