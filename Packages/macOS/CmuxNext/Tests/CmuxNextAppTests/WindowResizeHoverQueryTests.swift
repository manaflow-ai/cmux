import AppKit
@testable import CmuxNextApp
@testable import CmuxNextDesign
@testable import CmuxNextLayout
import Testing

/// WINDOW RESIZE 2 (Chrome parity row 5): a step of a window edge drag has one refresh (8.33 ms at 120 Hz) of main
/// thread time. A sample of a live corner drag with Home content (aws-m4pro-8, Release build of c9dcb70662f8, 4 drags)
/// showed a window server round trip in each step, more than one time: the layout moved a divider under the pointer
/// (`ScreenContentView.applyPresentation` -> `ScreenDividers.refreshHover`), and the overlay's catcher sync asked
/// again (`WindowOverlayLayer.syncCatchers` -> `LayoutRootView.refreshDividerHover`). Each ask is
/// `NSWindow.windowNumber(at:belowWindowWithWindowNumber:)`: 372 of the 938 samples of the resize layout pass.
///
/// The question is "which window is on top under the pointer". In a live resize the person holds the mouse button
/// on the window's own edge and AppKit's resize loop has the pointer: the answer of the drag's first step holds
/// until the drag ends. Chrome does the same job with no synchronous window server call in a resize frame.
///
/// A window enters a live resize through AppKit's notification, which the test posts to a private center for its
/// own window. The test is synchronous.
@MainActor @Suite(.serialized, .closesItsWindows) struct WindowResizeHoverQueryTests {
    static let start = CGSize(width: 1280, height: 800), end = CGSize(width: 1040, height: 640)
    static let steps = 20

    @MainActor final class Asks {
        var count = 0
        /// What the window server says: this window is on top under the pointer.
        var reaches = true
        /// The ask (by its number) that gets the other answer; none by default.
        var otherAt = -1
        func ask() -> Bool {
            count += 1
            return count == otherAt ? !reaches : reaches
        }
    }

    /// `body` runs with a live-resize tracker on a private center in place of the app's.
    private static func tracked(_ body: (NotificationCenter) throws -> Void) rethrows {
        let center = NotificationCenter()
        let app = LiveResizeWindows.shared
        LiveResizeWindows.shared = LiveResizeWindows(center: center)
        defer { LiveResizeWindows.shared = app }
        try body(center)
    }

    @Test func aResizeStepAsksTheWindowServerNothingForTheDividerUnderThePointer() throws {
        // The fixture of DividerCursorNoRegionRebuildTests: a row divider inside the second column.
        let columns = (0..<2).map { PaneMotionBench.column($0, rows: 3, width: 0.5) }
        let probe = LayoutWorkProbe(.columns(columns), size: Self.start, focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen, window = probe.window
        let handle = try #require(screen.dividerViews[.split("s1-0")], "fixture: no divider")
        // The pointer stays on the divider, as it stays on the window's corner (and the handle there) in a real drag.
        probe.root.context.hoverPointer = { _ in screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil) }
        let asks = Asks()
        probe.root.context.hoverReachesWindow = { _ in asks.ask() }
        probe.root.refreshDividerHover()
        try #require(handle.isHovered && asks.count == 1, "fixture: the divider under the pointer is not hovered (asks \(asks.count))")

        try Self.tracked { center in
            center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            try #require(Motion.isLiveResizing(window), "fixture: the window is not in a live resize")
            let before = asks.count, place = handle.frame
            // Review of #40659 (finding 3): the first ask of a drag comes from the layout pass, before the page windows
            // and the catcher panels of that step are in their places, so it can meet a window that is on top only
            // until the step ends. That answer must not stay for the drag: the ask after the first catcher sync does.
            asks.otherAt = before + 1
            for step in 1...Self.steps {
                let t = CGFloat(step) / CGFloat(Self.steps)
                let size = CGSize(width: Self.start.width + (Self.end.width - Self.start.width) * t,
                                  height: Self.start.height + (Self.end.height - Self.start.height) * t)
                window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
                probe.root.layoutSubtreeIfNeeded()
                // The overlay's catcher sync of the step asks for the hover again (`WindowOverlayLayer.syncCatchers`).
                probe.root.refreshDividerHover()
            }
            try #require(handle.frame != place, "fixture: the divider did not move in the resize")
            let inDrag = asks.count - before
            print("WORK case=window-resize-hover steps=\(Self.steps) hover_queries=\(inDrag)")
            #expect(inDrag <= 2, "\(inDrag) window server asks in \(Self.steps) steps of a live resize (two at most, both in the first step)")
            #expect(handle.isHovered, "the divider under the pointer lost its hover in the resize")

            // The drag ends: the held answer ends with it, and the next refresh asks again.
            center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            let after = asks.count
            probe.root.refreshDividerHover()
            #expect(asks.count == after + 1, "after the resize the hover asks the window server again")
        }
    }

    /// Review of #40659 (finding 1): the held answer ends with its resize, also when nothing asks between two resizes
    /// (no handle is under the pointer then) and when the first one is a full screen transition, which ends with no
    /// `viewDidEndLiveResize`. The first ask of the next resize goes to the window server.
    @Test func aSecondResizeDoesNotUseTheAnswerOfTheFirst() throws {
        let columns = (0..<2).map { PaneMotionBench.column($0, rows: 3, width: 0.5) }
        let probe = LayoutWorkProbe(.columns(columns), size: Self.start, focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen, window = probe.window
        let handle = try #require(screen.dividerViews[.split("s1-0")], "fixture: no divider")
        probe.root.context.hoverPointer = { _ in screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil) }
        let asks = Asks()
        probe.root.context.hoverReachesWindow = { _ in asks.ask() }
        let firsts = [(NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification),
                      (NSWindow.willStartLiveResizeNotification, NSWindow.didEndLiveResizeNotification)]
        try Self.tracked { center in
            for (began, ended) in firsts {
                // The first one: this window is on top under the pointer, and the divider is hovered.
                asks.reaches = true
                center.post(name: began, object: window)
                try #require(Motion.isLiveResizing(window), "fixture: \(began.rawValue) did not start a live resize")
                probe.root.refreshDividerHover()
                probe.root.refreshDividerHover()
                try #require(handle.isHovered, "fixture: the divider under the pointer is not hovered")
                center.post(name: ended, object: window)
                try #require(!Motion.isLiveResizing(window), "fixture: \(ended.rawValue) did not end the live resize")

                // Nothing asks between the two. Now another window is on top under the pointer.
                asks.reaches = false
                let before = asks.count
                center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
                // A step's layout pass asks for the hover with no word that the windows changed.
                screen.refreshDividerHover()
                #expect(asks.count == before + 1, "after \(began.rawValue): the next resize asked the window server \(asks.count - before) times at its first step")
                #expect(!handle.isHovered, "after \(began.rawValue): the next resize shows the hover of the one before")
                center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            }
        }
    }

    /// With no live resize the hover asks each time the windows may have changed, as before (a guard).
    @Test func withNoLiveResizeEachRefreshAsksAgain() throws {
        let columns = (0..<2).map { PaneMotionBench.column($0, rows: 3, width: 0.5) }
        let probe = LayoutWorkProbe(.columns(columns), size: Self.start, focused: PaneID("p0-0"))
        defer { probe.close() }
        let screen = probe.screen
        let handle = try #require(screen.dividerViews[.split("s1-0")], "fixture: no divider")
        probe.root.context.hoverPointer = { _ in screen.convert(CGPoint(x: handle.frame.midX, y: handle.frame.midY), to: nil) }
        let asks = Asks()
        probe.root.context.hoverReachesWindow = { _ in asks.ask() }
        Self.tracked { _ in
            for _ in 0..<3 { probe.root.refreshDividerHover() }
        }
        #expect(asks.count == 3, "3 refreshes with no live resize asked \(asks.count) times")
    }
}
