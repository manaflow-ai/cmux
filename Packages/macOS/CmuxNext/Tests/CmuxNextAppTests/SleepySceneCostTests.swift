import AppKit
@testable import CmuxNextApp
import CmuxNextDesign
import Foundation
import Testing

/// Sleepy Mode's scene costs the main thread nothing per frame (every-action sweep, m27
/// other-main-work: `SleepySceneView.drawSky` held main 20-38 ms per frame, ten frames a
/// second, while the scene showed and agents kept working). The sky's loops run in the render
/// server; the main thread only updates the clock once a second.
@MainActor @Suite(.serialized) struct SleepySceneCostTests {
    /// Runs the main run loop for `seconds`.
    private func spin(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test(.enabled(if: NSScreen.main != nil, "the scene draws only on a screen: run on a GUI host"))
    func aSecondOfTheSceneCostsTheMainThreadUnder30Milliseconds() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        try #require(Motion.panes.animatesLoops, "loops are off on this host: only the still sky would show")
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SleepySceneView.hostView(workingAgents: { 0 }, wake: {}, lockMac: {})
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        defer { window.close() }
        // The first layout and draw are not per-frame work.
        spin(0.5)
        let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        spin(1)
        let usedMs = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1e6
        #expect(usedMs < 30, "the scene used \(usedMs) ms of main-thread CPU in one second on a \(screen.frame.size) screen")
    }
}
