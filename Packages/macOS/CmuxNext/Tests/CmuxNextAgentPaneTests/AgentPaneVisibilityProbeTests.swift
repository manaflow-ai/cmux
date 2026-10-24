import AppKit
@testable import CmuxNextAgentPane
import CmuxNextDesign
import Testing

/// An agent pane's frame pacer hears its window come back through a zero-size probe view. Each
/// probe had an occlusion observer of its own, so a window with N chats had N observers of one
/// notice; the probes now follow the window's ``WindowOcclusionFamily`` (one observer per window,
/// PATTERNS.md P3), and each still hears every change of its own window only.
@MainActor
@Suite struct AgentPaneVisibilityProbeTests {
    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func theProbesOfOneWindowShareItsFamilyAndHearOnlyTheirWindow() throws {
        let center = NotificationCenter()
        let measured = Self.window(), other = Self.window()
        let family = WindowOcclusionFamily.of(measured, center: center)
        _ = WindowOcclusionFamily.of(other, center: center)
        var heard = [0, 0, 0]
        let probes = (0..<3).map { index in
            let probe = AgentPaneVisibilityProbe(frame: .zero)
            probe.onChange = { heard[index] += 1 }
            return probe
        }
        try #require(measured.contentView).addSubview(probes[0])
        try #require(measured.contentView).addSubview(probes[1])
        try #require(other.contentView).addSubview(probes[2])
        #expect(family.followerCount == 2, "each probe kept an observer of its own")
        heard = [0, 0, 0]

        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.post(name: name, object: measured)
        }
        #expect(heard == [3, 3, 0])

        // Out of the window: no longer called, and the family observes nothing with no follower.
        probes[0].removeFromSuperview()
        probes[1].removeFromSuperview()
        #expect(family.followerCount == 0)
        #expect(!family.isObserving)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: measured)
        #expect(heard == [4, 4, 0]) // the move out of the window itself, nothing from the notice
    }
}
