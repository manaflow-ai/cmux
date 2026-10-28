import AppKit
@testable import CmuxNextApp
import Foundation
import Observation
import Testing

/// A fake of the app's agent facts: an observable count, and how often the scene read it.
@Observable @MainActor private final class FakeAgentCount {
    var working = 0
    @ObservationIgnored var reads = 0
}

/// Sleepy Mode's scene wakes only for what it shows (p14-energy-057): the HH:MM clock once a
/// minute, and the agent line when an observed agent fact changes. It used to run a
/// once-a-second timeline that read the count and redrew both every second.
@MainActor @Suite(.serialized) struct SleepySceneWakeTests {
    /// Runs the main run loop for `seconds`.
    private func spin(_ seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    @Test(.enabled(if: NSScreen.main != nil, "the scene draws only on a screen: run on a GUI host"))
    func theAgentLineReadsTheCountWhenItChangesAndNotOnATimer() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let count = FakeAgentCount()
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SleepySceneView.hostView(workingAgents: {
            count.reads += 1
            return count.working
        }, wake: {}, lockMac: {})
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        defer { window.close() }
        spin(0.5)
        let settled = count.reads
        #expect(settled >= 1, "the scene never drew the agent line")

        spin(2.5)
        #expect(count.reads == settled, "nothing changed, yet the scene read the agent count \(count.reads - settled) more times")

        count.working = 2
        spin(0.3)
        #expect(count.reads > settled, "a turn started and the agent line did not read the count again")
    }
}
