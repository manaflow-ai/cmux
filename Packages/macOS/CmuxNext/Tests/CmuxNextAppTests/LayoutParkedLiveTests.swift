import AppKit
@testable import CmuxNextLayout
import CmuxNextDesign
import CmuxNextTestSupport
import Testing

/// A layout under a parked, unhidden workspace (`ParkingContainer`) is not live, as a hidden one is
/// not: no event monitor, no frame driver, no overlay plane. Showing it makes it live again.
@MainActor
@Suite(.closesItsWindows)
struct LayoutParkedLiveTests {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
    }

    final class Container: NSView, ParkingContainer {
        var isParkedOffScreen = false
        func park(_ parked: Bool) {
            isParkedOffScreen = parked
            notifyParkingChange()
        }
    }

    @Test func parkingWithoutHidingTakesTheLayoutOffLine() {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1")))],
                                activeScreenID: "s1", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        let container = Container(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.frame = container.bounds
        container.addSubview(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = container
        root.layoutSubtreeIfNeeded()
        #expect(root.isLive)
        container.park(true)
        #expect(!root.isLive)
        #expect(!root.driver.isAttached)
        #expect(root.paneCardsInWindow.isEmpty)
        container.park(false)
        #expect(root.isLive)
        #expect(root.driver.isAttached)
    }

    /// A split of p1 and p2 in a parking container, in a window, with the test as the clock.
    static func pair() -> (model: LayoutModel, root: LayoutRootView, container: Container, window: NSWindow) {
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(
            .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))))], activeScreenID: "s1", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: Panes())
        root.context.reduceMotionOverride = false
        let container = Container(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.frame = container.bounds
        container.addSubview(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = container
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        return (model, root, container, window)
    }

    /// A ratio change still springing when its workspace parks lands in the park, and the layout is still: the window's
    /// divider catchers and page geometry follow the landing (`isInLayoutMotion` false), never wait for a frame that no
    /// motion asks for (a pane whose neighbour changed size stayed unclickable).
    @Test func aRatioChangeSpringingWhenItsWorkspaceParksEndsTheMotion() throws {
        let (model, root, container, window) = Self.pair()
        defer { window.closeAfterTest() }
        var heard: [Bool] = []
        let observer = root.observeLayoutMotion { heard.append($0) }
        defer { _ = observer }
        model.apply(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(
            .split("r", axis: .horizontal, ratio: 0.3, a: .leaf("p1"), b: .leaf("p2"))))])
        root.syncWithModel()
        #expect(root.advanceFrame(1.0 / 120), "the ratio change springs")
        #expect(root.isInLayoutMotion)
        container.park(true)
        #expect(!root.isInLayoutMotion, "the park landed the change: the motion ended")
        #expect(heard.last == false)
        container.park(false)
        #expect(!root.isInLayoutMotion)
        let shown = try #require(root.screenViews["s1"]?.paneFrames["p1"])
        #expect(shown.rect == shown.targetRect, "the pane rests at its new size")
    }

    /// A close is one commit that waits for its frame tick. When its workspace parks before that tick, the park shows
    /// the close: the pane that stays has its place, the closed pane is hidden, and the layout is still, so nothing
    /// waits for a frame that no motion asks for (a pane whose right split closed stayed unclickable).
    @Test func aCloseWaitingForItsFrameWhenItsWorkspaceParksShowsInThePark() throws {
        let (model, root, container, window) = Self.pair()
        defer { window.closeAfterTest() }
        var heard: [Bool] = []
        let observer = root.observeLayoutMotion { heard.append($0) }
        defer { _ = observer }
        let kept = try #require(root.context.hosts["p1"]), closed = try #require(root.context.hosts["p2"])
        let before = kept.frame
        model.apply(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1")))])
        root.syncWithModel()
        #expect(kept.frame == before && !closed.isHidden, "the close showed before its frame tick: \(kept.frame)")
        #expect(!root.isInLayoutMotion, "a close that springs nothing is a layout motion")
        container.park(true)
        #expect(closed.isHidden && kept.frame.width > before.width, "the park did not show the close: \(kept.frame), closed pane hidden \(closed.isHidden)")
        #expect(!root.isInLayoutMotion && heard.allSatisfy { !$0 }, "the close was told as a layout motion: \(heard)")
        container.park(false)
        #expect(!root.isInLayoutMotion)
        let shown = try #require(root.screenViews["s1"]?.paneFrames["p1"])
        #expect(shown.rect == shown.targetRect && kept.frame == root.screenViews["s1"]?.displayedFrame(of: "p1"), "the pane rests at its full size")
    }

    /// A screen switch is complete in its own turn (no slide), so a workspace that parks right after one is still: the
    /// park has nothing of the switch to land, and the show finds the new screen in place and starts no frame.
    @Test func aScreenSwitchBeforeItsWorkspaceParksLeavesNothingToLand() throws {
        let provider = Panes()
        let model = LayoutModel(screens: [LayoutScreen(id: "s1", name: "s1", layout: .splits(.leaf("p1"))),
                                          LayoutScreen(id: "s2", name: "s2", layout: .splits(.leaf("p2")))],
                                activeScreenID: "s1", focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let container = Container(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        root.frame = container.bounds
        container.addSubview(root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        defer { window.closeAfterTest() }
        window.contentView = container
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        model.selectScreen("s2")
        root.syncWithModel()
        let incoming = try #require(root.screenViews["s2"]), outgoing = try #require(root.screenViews["s1"])
        #expect(!root.isInLayoutMotion, "the switch put the layout in motion")
        #expect(!root.advanceFrame(1.0 / 120), "the switch left something to move")
        container.park(true)
        #expect(!root.isInLayoutMotion)
        #expect(!incoming.isHidden && incoming.frame == root.bounds && incoming.alphaValue == 1, "the park moved the shown screen")
        #expect(outgoing.isHidden)
        container.park(false)
        #expect(root.isLive)
        #expect(!root.advanceFrame(1.0 / 120), "the show started a motion")
        #expect(!incoming.isHidden && incoming.frame == root.bounds && incoming.alphaValue == 1, "the show moved the shown screen")
        #expect(outgoing.isHidden)
    }
}
