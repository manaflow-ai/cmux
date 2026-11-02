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
}
