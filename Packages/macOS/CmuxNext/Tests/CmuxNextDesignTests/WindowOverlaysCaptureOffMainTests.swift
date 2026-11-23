import AppKit
@testable import CmuxNextDesign
import CmuxNextTestSupport
import Darwin
import os
import Testing

/// A window's composite with its overlays reads only window numbers and the frame on the main
/// actor: the window server calls (its window list, the composites, the blank checks and the overlay
/// mask) run off it. `debug.window_snapshot` takes one every second while a journey films a motion;
/// on the main thread each one was a 15-38 ms missed refresh in every film (RESIZE P0, 2026-11-07).
@MainActor
@Suite(.closesItsWindows) struct WindowOverlaysCaptureOffMainTests {
    @Test func theWindowServerCaptureRunsOffTheMainThread() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        try #require(window.windowNumber > 0, "no window server connection on this host")

        let onMainThread = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let plans = OSAllocatedUnfairLock<[WindowOverlaysCapturePlan]>(initialState: [])
        let result = await window.compositedImageWithOverlays(cuttingOverlays: { _ in true }) { plan in
            onMainThread.withLock { $0.append(pthread_main_np() != 0) }
            plans.withLock { $0.append(plan) }
            return nil
        }

        #expect(result == nil)
        #expect(onMainThread.withLock { $0 } == [false])
        let plan = try #require(plans.withLock { $0 }.first)
        #expect(plan.window == window.windowNumber)
        #expect(plan.cutChildren == [])
    }
}
