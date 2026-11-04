import AppKit
@testable import CmuxNextApp
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

    /// Runs the main run loop until `done` or 3 s (the resize animation lands on the run loop).
    private func runUntil(_ done: () -> Bool) {
        let end = Date(timeIntervalSinceNow: 3)
        while !done(), Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test(.enabled(if: NSScreen.main != nil, "zooming needs a screen: run on a GUI host")) func aZoomReturnsBeforeTheWindowResizesAndLandsOnTheRunLoop() throws {
        let (window, start) = try shownWindow()
        defer { window.close() }
        try #require(!window.isZoomed)
        window.zoom(nil)
        #expect(window.frame == start, "zoom resized the window inside its own call (\(window.frame)): the animation held the main thread")
        #expect(window.isZoomed, "a zoom on its way to the standard frame counts as zoomed")
        runUntil { window.frame != start && !window.inLiveResize && window.isZoomed && window.frame.width > start.width + 1 }
        #expect(window.frame.width > start.width, "the window reached its zoomed frame on the run loop")
        window.zoom(nil)
        runUntil { abs(window.frame.width - start.width) <= 1 && abs(window.frame.height - start.height) <= 1 }
        #expect(abs(window.frame.width - start.width) <= 1 && abs(window.frame.minY - start.minY) <= 1,
                "the second zoom went back to \(start), the window is at \(window.frame)")
    }

    // MARK: chrome-parity p03-rendering-105: a zoom resizes each terminal's grid once

    final class Terminal: ResizeTarget {
        var applied: [CellSize] = []
        var awaitsEcho = false
        func applySettled(_ size: CellSize) { applied.append(size) }
    }

    /// A zoom holds nothing (the frame-animation hold was removed, prove-or-remove 11-04): each step's
    /// terminal grid goes to the daemon on the next frame.
    /// skip-owner: PL-rendering; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
    @Test(.enabled(if: NSScreen.main != nil, "zooming needs a screen: run on a GUI host")) func withTheHoldOffAZoomResizesTerminalsLive() throws {
        let (window, start) = try shownWindow()
        defer { window.close() }
        let coordinator = ResizeCoordinator()
        let terminal = Terminal()
        window.zoom(nil)
        #expect(!Motion.holdsContentResize(window), "the zoom held its window's grids")
        coordinator.submit(terminal, size: CellSize(cols: 130, rows: 40), window: window)
        while coordinator.tick() {}
        #expect(terminal.applied == [CellSize(cols: 130, rows: 40)], "a mid-zoom grid waited for the landing: \(terminal.applied)")
        runUntil { window.frame.width > start.width + 1 && window.isZoomed }
        #expect(window.frame.width > start.width, "the zoom did not land")
    }
}
