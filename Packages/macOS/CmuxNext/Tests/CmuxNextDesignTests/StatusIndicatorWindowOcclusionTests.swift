import AppKit
@testable import CmuxNextDesign
import Testing

/// A chrome spinner that follows its own window's occlusion (`tracksWindowOcclusion`: Home's first
/// run, pane headers, hover cards, the palette) had an occlusion observer of its own, so a window
/// with N of them had N observers of one notice. They now follow the window's
/// ``WindowOcclusionFamily`` (one observer per window, PATTERNS.md P3); each still hears every
/// change of its own window only, and a spinner whose host tracks occlusion follows nothing.
@MainActor
@Suite struct StatusIndicatorWindowOcclusionTests {
    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func spinner(in window: NSWindow, tracks: Bool) throws -> StatusIndicatorView {
        let view = StatusIndicatorView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        view.tracksWindowOcclusion = tracks
        try #require(window.contentView).addSubview(view)
        return view
    }

    @Test func theSpinnersOfOneWindowShareItsFamilyAndHearOnlyTheirWindow() throws {
        let center = NotificationCenter()
        let measured = Self.window(), other = Self.window()
        let family = WindowOcclusionFamily.of(measured, center: center)
        _ = WindowOcclusionFamily.of(other, center: center)
        let tracking = [try Self.spinner(in: measured, tracks: true), try Self.spinner(in: measured, tracks: true)]
        let hosted = try Self.spinner(in: measured, tracks: false)
        let elsewhere = try Self.spinner(in: other, tracks: true)
        #expect(family.followerCount == 2, "each spinner kept an occlusion observer of its own")

        // Each starts from the opposite of its window's state, so the check holds on a host whose
        // windows never report visible (headless CI) as well as on one where they do.
        let visible = measured.occlusionState.contains(.visible)
        let otherVisible = other.occlusionState.contains(.visible)
        for view in tracking + [hosted] { view.isWindowVisible = !visible }
        elsewhere.isWindowVisible = !otherVisible
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: measured)
        #expect(tracking.allSatisfy { $0.isWindowVisible == visible }, "a spinner missed its window's notice")
        #expect(hosted.isWindowVisible == !visible, "a spinner whose host tracks occlusion followed the window")
        #expect(elsewhere.isWindowVisible == !otherVisible, "another window's notice reached a spinner")

        // Tracking turned off, then out of the window: the family has no follower left.
        tracking[0].tracksWindowOcclusion = false
        #expect(family.followerCount == 1)
        tracking[1].removeFromSuperview()
        #expect(family.followerCount == 0)
        #expect(!family.isObserving)
    }
}
