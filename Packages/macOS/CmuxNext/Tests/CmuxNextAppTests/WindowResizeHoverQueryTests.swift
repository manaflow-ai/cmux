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

    @MainActor final class Asks { var count = 0 }

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
        probe.root.context.hoverReachesWindow = { _ in
            asks.count += 1
            return true
        }
        probe.root.refreshDividerHover()
        try #require(handle.isHovered && asks.count == 1, "fixture: the divider under the pointer is not hovered (asks \(asks.count))")

        try Self.tracked { center in
            center.post(name: NSWindow.willStartLiveResizeNotification, object: window)
            try #require(Motion.isLiveResizing(window), "fixture: the window is not in a live resize")
            let before = asks.count, place = handle.frame
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
            #expect(inDrag <= 1, "\(inDrag) window server asks in \(Self.steps) steps of a live resize (one at most: the first step's)")
            #expect(handle.isHovered, "the divider under the pointer lost its hover in the resize")

            // The drag ends: the held answer ends with it, and the next refresh asks again.
            center.post(name: NSWindow.didEndLiveResizeNotification, object: window)
            let after = asks.count
            probe.root.refreshDividerHover()
            #expect(asks.count == after + 1, "after the resize the hover asks the window server again")
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
        probe.root.context.hoverReachesWindow = { _ in
            asks.count += 1
            return true
        }
        Self.tracked { _ in
            for _ in 0..<3 { probe.root.refreshDividerHover() }
        }
        #expect(asks.count == 3, "3 refreshes with no live resize asked \(asks.count) times")
    }
}
