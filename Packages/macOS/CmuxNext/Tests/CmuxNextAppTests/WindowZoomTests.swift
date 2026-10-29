import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextBridge
import CmuxNextWakeupsTestSupport
import struct CmuxNextDaemon.CellSize
@testable import CmuxNextDesign
import CmuxNextSidebar
import CmuxNextWakeups
import Foundation
import Testing

/// Zoom never holds the key's turn for its animation (every-action sweep, zoomWindow: 380 ms in the
/// handler on macOS 27, light and STRESS: AppKit's `zoom(_:)` resizes with
/// `setFrame(_:display:animate: true)`, which runs the whole animation before it returns). The
/// zoom returns at once and the window reaches its zoomed frame on the run loop; a second zoom
/// goes back to the frame it came from.
@MainActor @Suite(.serialized) struct WindowZoomTests {
    private func shownWindow() throws -> (ShellWindow, NSRect) {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main, "zooming needs a screen")
        let root = WindowRootView(sidebar: SidebarContainerView(model: SidebarModel(), mainWork: MainWorkScheduler(budget: MainFrameBudget())), revealDeadlines: .testing())
        let window = ShellWindow(contentRect: root.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        let visible = screen.visibleFrame
        let start = NSRect(x: visible.minX + 40, y: visible.minY + 40, width: 900, height: 600)
        window.setFrame(start, display: false)
        window.orderFrontRegardless()
        return (window, start)
    }

    /// Runs the main run loop until `done` or `seconds` (the resize animation lands on the run loop),
    /// and prints how it ended.
    private func runUntil(_ what: String, _ window: NSWindow, seconds: TimeInterval, _ done: () -> Bool) {
        let begin = Date()
        let end = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        print("WindowZoomTests: \(what): done=\(done()) after \(Date().timeIntervalSince(begin)) s, frame \(window.frame), "
            + "isZoomed \(window.isZoomed), inLiveResize \(window.inLiveResize), visible \(window.screen?.visibleFrame ?? .zero)")
    }

    @Test(.enabled(if: NSScreen.main != nil, "zooming needs a screen: run on a GUI host")) func aZoomReturnsBeforeTheWindowResizesAndLandsOnTheRunLoop() throws {
        let (window, start) = try shownWindow()
        defer { window.close() }
        try #require(!window.isZoomed)
        // The zoom animates only when the panes' Motion gate lets it (`WindowZoom` resizes through
        // `Motion.panes.animateTimed`). With Reduce Motion, calm mode, animations off, a live resize or
        // a sleeping display it snaps by design, so "returns before the window resizes" does not apply.
        // Read with the zoom's own inputs, just before it, so nothing changes in between.
        let policy = Motion.panes.policy
        guard Motion.panes.canAnimate(in: window.contentView), policy.duration(.move) > 0 else {
            print("WindowZoomTests: skipped, the zoom snaps on this host by design: canAnimate=\(Motion.panes.canAnimate(in: window.contentView)) "
                + "speed=\(policy.speed) animationsEnabled=\(policy.animationsEnabled) reduceMotion=\(policy.reduceMotion) "
                + "liveResize=\(policy.liveResize) panesOff=\(policy.disabledCategories.contains(.panes))")
            return
        }
        window.zoom(nil)
        #expect(window.frame == start, "zoom resized the window inside its own call (\(window.frame)): the animation held the main thread")
        #expect(window.isZoomed, "a zoom on its way to the standard frame counts as zoomed")
        // The test checks where the window lands, not how fast: a loaded runner may take far longer than
        // the animation's own length, so the wait for the frame is a 30 s hang guard. Then up to 3 s (the
        // test's old wait) for the animation to leave live resize; on some CI runners AppKit keeps the
        // window in live resize after the frame landed, and the second zoom then snaps, which is fine.
        runUntil("zoom in", window, seconds: 30) { window.isZoomed && window.frame.width > start.width + 1 }
        runUntil("zoom in settles", window, seconds: 3) { !window.inLiveResize }
        #expect(window.frame.width > start.width, "the window reached its zoomed frame on the run loop")
        window.zoom(nil)
        runUntil("zoom back", window, seconds: 30) { abs(window.frame.width - start.width) <= 1 && abs(window.frame.height - start.height) <= 1 }
        #expect(abs(window.frame.width - start.width) <= 1 && abs(window.frame.minY - start.minY) <= 1,
                "the second zoom went back to \(start), the window is at \(window.frame)")
    }

    // MARK: chrome-parity p03-rendering-105: a zoom resizes each terminal's grid once

    final class Terminal: ResizeTarget {
        var applied: [CellSize] = []
        var awaitsEcho = false
        func applySettled(_ size: CellSize) { applied.append(size) }
    }

    /// While a zoom animates the window's frame, every step lays the terminal out at another size;
    /// the daemon gets one grid, the newest, after the zoom lands. Another window's terminal does
    /// not wait.
    @Test func aFrameAnimationHoldsItsWindowsGridsUntilItEnds() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                             backing: .buffered, defer: true)
        let coordinator = ResizeCoordinator()
        let terminal = Terminal()
        let elsewhere = Terminal()
        Motion.beginFrameAnimation(window)
        defer { while Motion.holdsContentResize(window) { Motion.endFrameAnimation(window) } }
        #expect(!Motion.holdsContentResize(other), "a zoom in one window held another window's content")
        for (step, cols) in [100, 130, 160, 190, 212].enumerated() {
            coordinator.submit(terminal, size: CellSize(cols: cols, rows: 30 + step), window: window)
            _ = coordinator.tick()
        }
        coordinator.submit(elsewhere, size: CellSize(cols: 80, rows: 24), window: other)
        _ = coordinator.tick()
        #expect(terminal.applied.isEmpty, "the daemon reflowed the PTY for the zoom's steps: \(terminal.applied)")
        #expect(elsewhere.applied == [CellSize(cols: 80, rows: 24)], "another window's terminal waited for the zoom")
        // A second press while the first animates: the hold lasts until both have ended.
        Motion.beginFrameAnimation(window)
        Motion.endFrameAnimation(window)
        #expect(Motion.holdsContentResize(window), "the first zoom's end released the second's hold")
        _ = coordinator.tick()
        #expect(terminal.applied.isEmpty)
        Motion.endFrameAnimation(window)
        #expect(!Motion.holdsContentResize(window))
        while coordinator.tick() {}
        #expect(terminal.applied == [CellSize(cols: 212, rows: 34)], "the zoom's final grid went \(terminal.applied)")
    }

    @Test func aClosedWindowHoldsNothing() {
        let center = NotificationCenter()
        let windows = LiveResizeWindows(center: center)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        windows.beginFrameAnimation(of: window)
        windows.beginFrameAnimation(of: window)
        #expect(windows.isFrameAnimating(window))
        #expect(!windows.isActive, "one window's zoom snapped every window's motion")
        center.post(name: NSWindow.willCloseNotification, object: window)
        #expect(!windows.isFrameAnimating(window), "a window closed mid-zoom held its grids")
        windows.endFrameAnimation(of: window)
        #expect(!windows.isFrameAnimating(window), "a late completion after the close reopened a hold")
    }

    /// Feature `windowFrameAnimationHoldsContent` on: the zoom itself holds its window from the
    /// press to its landing, and no longer.
    @Test(.enabled(if: NSScreen.main != nil, "zooming needs a screen: run on a GUI host")) func aZoomHoldsItsWindowsContentUntilItLands() throws {
        let (window, start) = try shownWindow()
        defer { window.close() }
        window.zoomHoldsContent = true
        window.zoom(nil)
        #expect(Motion.holdsContentResize(window), "the zoom's steps resize the terminals")
        runUntil { !Motion.holdsContentResize(window) }
        #expect(!Motion.holdsContentResize(window), "the zoom held its window's grids after it landed")
        #expect(window.frame.width > start.width, "the zoom did not land")
    }

    /// Feature `windowFrameAnimationHoldsContent` off (its default): a zoom holds nothing, so each
    /// step's terminal grid goes to the daemon on the next frame, as before the hold existed.
    @Test(.enabled(if: NSScreen.main != nil, "zooming needs a screen: run on a GUI host")) func withTheHoldOffAZoomResizesTerminalsLive() throws {
        let (window, start) = try shownWindow()
        defer { window.close() }
        #expect(!window.zoomHoldsContent, "the hold is on by default")
        let coordinator = ResizeCoordinator()
        let terminal = Terminal()
        window.zoom(nil)
        #expect(!Motion.holdsContentResize(window), "the zoom held its window's grids with the feature off")
        coordinator.submit(terminal, size: CellSize(cols: 130, rows: 40), window: window)
        while coordinator.tick() {}
        #expect(terminal.applied == [CellSize(cols: 130, rows: 40)], "a mid-zoom grid waited for the landing: \(terminal.applied)")
        runUntil { window.frame.width > start.width + 1 && window.isZoomed }
        #expect(window.frame.width > start.width, "the zoom did not land")
    }
}
