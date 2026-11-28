import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// A person's divider drag reaches the pane contents that follow it their own way
/// (`PaneResizeGestureFollowing`, a Chromium page): `true` on the first move, `false` once, after the
/// release's spring landed, with the pane at its final frame. A click on the divider tells nothing.
/// Leo, 2026-10-26: "resizing the panes it propagates so fucking slowly to the right side browser tab thing".
@MainActor
@Suite(.closesItsWindows)
struct PaneResizeGestureTests {
    final class Follower: NSView, PaneResizeGestureFollowing {
        var heard: [Bool] = []
        /// The pane host's frame when `false` came.
        var frameAtEnd: CGRect?
        func paneResizeGestureDidChange(active: Bool) {
            heard.append(active)
            if !active { frameAtEnd = superview?.superview?.frame }
        }
    }

    final class Panes: LayoutPaneContentProvider {
        let follower = Follower()
        func makeContentView(for pane: PaneID) -> NSView { pane == "p2" ? follower : NSView() }
    }

    final class Harness {
        let provider = Panes()
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init() {
            _ = NSApplication.shared
            let columns = [LayoutColumn(id: "c0", width: 1, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")))]
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "p1")
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.driver.isManual = true
        }

        var handle: DividerHandleView {
            get throws { try #require(root.screenViews["s"]?.dividerViews[.split("x")]) }
        }

        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func center() throws -> CGPoint {
            let handle = try handle
            return handle.convert(CGPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
        }

        func frame() { _ = root.advanceFrame(1.0 / 120) }

        /// Steps display frames until nothing moves (at most 2 s of them).
        func land() {
            var frames = 0
            while frames < 240, root.advanceFrame(1.0 / 120) {
                root.layoutSubtreeIfNeeded()
                frames += 1
            }
            root.layoutSubtreeIfNeeded()
        }
    }

    @Test func aDragTellsTheFollowerOnceAtTheStartAndOnceWhenItsReleaseLanded() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        #expect(harness.provider.follower.heard.isEmpty, "the press alone told \(harness.provider.follower.heard)")
        for step in 1...20 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 8, y: start.y)))
            harness.root.syncWithModel()
            harness.frame()
            harness.root.layoutSubtreeIfNeeded()
        }
        #expect(harness.provider.follower.heard == [true])
        handle.mouseUp(with: harness.event(.leftMouseUp, CGPoint(x: start.x - 160, y: start.y)))
        // No sync here: a display frame may come before the observation applies the release, and the
        // end must still wait for the release's layout and its landing.
        harness.land()
        #expect(harness.provider.follower.heard == [true, false])
        let host = try #require(harness.root.context.hosts["p2"])
        #expect(harness.provider.follower.frameAtEnd == host.frame, "the follower heard the end before the pane landed")
    }

    @Test func reduceMotionDuringTheLandingStillEndsTheDrag() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        for step in 1...10 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 12, y: start.y)))
            harness.root.syncWithModel()
            harness.frame()
        }
        handle.mouseUp(with: harness.event(.leftMouseUp, CGPoint(x: start.x - 120, y: start.y)))
        harness.root.syncWithModel()
        harness.frame()
        harness.root.context.reduceMotionOverride = true
        harness.land()
        harness.frame()
        #expect(harness.provider.follower.heard == [true, false])
    }

    @Test func aWorkspaceHiddenMidDragEndsItAndTheNextDragStartsAgain() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let handle = try harness.handle
        let start = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, start))
        for step in 1...5 {
            handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: start.x - CGFloat(step) * 8, y: start.y)))
            harness.root.syncWithModel()
            harness.frame()
        }
        harness.root.isHidden = true
        #expect(harness.provider.follower.heard == [true, false])
        handle.mouseUp(with: harness.event(.leftMouseUp, CGPoint(x: start.x - 40, y: start.y)))
        harness.root.syncWithModel()
        harness.root.isHidden = false
        harness.land()
        let next = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, next))
        handle.mouseDragged(with: harness.event(.leftMouseDragged, CGPoint(x: next.x + 8, y: next.y)))
        #expect(harness.provider.follower.heard == [true, false, true])
    }

    @Test func aClickOnTheDividerTellsNothing() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let handle = try harness.handle
        let point = try harness.center()
        handle.mouseDown(with: harness.event(.leftMouseDown, point))
        handle.mouseUp(with: harness.event(.leftMouseUp, point))
        harness.root.syncWithModel()
        harness.land()
        #expect(harness.provider.follower.heard.isEmpty)
    }

    /// Leo, 2026-11-22: "interior resizing is good and fast. exterior (whole-window of app) resizing is bad". A person's
    /// live resize of the window is followed as a divider drag: `true` at its start, the pane views' frame notices held
    /// through it, `false` once at its end with the pane at its final frame, and the notices given back.
    @Test func aWindowLiveResizeIsFollowedAsADividerDrag() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.root.screenViews["s"])
        screen.windowLiveResizeBegan()
        #expect(harness.provider.follower.heard == [true])
        #expect(screen.paneFrameNotices.isHolding)
        screen.windowLiveResizeBegan()
        #expect(harness.provider.follower.heard == [true], "a second start told the follower again")
        for step in 1...10 {
            harness.window.setContentSize(NSSize(width: 1200 + step * 10, height: 800))
            harness.root.layoutSubtreeIfNeeded()
        }
        #expect(harness.provider.follower.heard == [true])
        screen.windowLiveResizeEnded()
        #expect(harness.provider.follower.heard == [true, false])
        let host = try #require(harness.root.context.hosts["p2"])
        #expect(harness.provider.follower.frameAtEnd == host.frame, "the follower heard the end before its pane's final frame")
        #expect(!screen.paneFrameNotices.isHolding)
        screen.windowLiveResizeEnded()
        #expect(harness.provider.follower.heard == [true, false], "an end with no start told the follower")
    }

    /// The sidebar's width motion resizes the content area in every frame as a window live resize does: the layout takes
    /// that resize's mode (frame notices held, out-of-view panes once at the end) without telling the drag followers, whose
    /// content keeps what it does in a spring; a person's live resize already under way keeps its own end.
    @Test func theSidebarMotionTakesTheLiveResizeModeWithoutFollowers() throws {
        let harness = Harness()
        defer { harness.window.closeAfterTest() }
        let screen = try #require(harness.root.screenViews["s"])
        harness.root.contentAreaMotionDidChange(active: true)
        #expect(screen.paneFrameNotices.isHolding)
        #expect(screen.windowResizeListeners?.isEmpty == true)
        for step in 1...10 {
            harness.window.setContentSize(NSSize(width: 1200 + step * 10, height: 800))
            harness.root.layoutSubtreeIfNeeded()
        }
        harness.root.contentAreaMotionDidChange(active: false)
        #expect(harness.provider.follower.heard.isEmpty, "the sidebar's motion told a drag follower")
        #expect(screen.windowResizeListeners == nil)
        #expect(!screen.paneFrameNotices.isHolding)

        screen.windowLiveResizeBegan()
        harness.root.contentAreaMotionDidChange(active: true)
        harness.root.contentAreaMotionDidChange(active: false)
        #expect(screen.windowResizeListeners != nil, "the sidebar's landing ended a person's live resize")
        screen.windowLiveResizeEnded()
        #expect(harness.provider.follower.heard == [true, false])
    }

    /// #50672: in a person's live resize of the window only the panes that show lay out each tick. A column scrolled past
    /// the screen's edge keeps its old size out of sight and lays out once at the end, before its contents hear the end.
    @Test func aWindowLiveResizeLaysOutAPaneOutOfViewOnceAtTheEnd() throws {
        _ = NSApplication.shared
        let provider = Panes()
        let columns = [LayoutColumn(id: "c0", width: 1, root: .leaf("p1")), LayoutColumn(id: "c1", width: 1, root: .leaf("p2"))]
        let model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(columns))], activeScreenID: "s",
                                focusedPane: "p1")
        let root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        defer { window.closeAfterTest() }
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        let screen = try #require(root.screenViews["s"])
        let shown = try #require(root.context.hosts["p1"]), away = try #require(root.context.hosts["p2"])
        try #require(screen.bounds.intersects(shown.frame))
        try #require(!screen.bounds.intersects(away.frame), "p2's column shows: \(away.frame) in \(screen.bounds)")
        let awaySize = away.frame.size

        screen.windowLiveResizeBegan()
        for step in 1...5 {
            window.setContentSize(NSSize(width: 1200 - step * 10, height: 800 - step * 10))
            root.layoutSubtreeIfNeeded()
        }
        let shownRest = try #require(screen.geometry.panes["p1"]), awayRest = try #require(screen.geometry.panes["p2"])
        #expect(abs(shown.frame.height - shownRest.height) < 1, "the pane that shows lags its frame: \(shown.frame) vs \(shownRest)")
        #expect(away.frame.size == awaySize, "the pane out of view laid out in a tick: \(away.frame)")
        #expect(screen.deferredOffscreenLayout)
        #expect(!screen.bounds.intersects(away.frame), "the held pane came into view: \(away.frame)")

        screen.windowLiveResizeEnded()
        #expect(!screen.deferredOffscreenLayout)
        #expect(abs(away.frame.height - awayRest.height) < 1 && abs(away.frame.width - awayRest.width) < 1,
                "the end left the pane out of view at its old size: \(away.frame) vs \(awayRest)")
    }
}
