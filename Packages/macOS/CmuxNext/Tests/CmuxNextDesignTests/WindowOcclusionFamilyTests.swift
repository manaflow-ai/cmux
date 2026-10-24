import AppKit
@testable import CmuxNextDesign
import Testing

/// A cmux page freezes while its window is covered, minimized or ordered out (perf-lead.md F3), so
/// each page must hear its window's occlusion. One family per window observes AppKit's notices
/// once (PATTERNS.md P3) and calls only that window's followers, and observes nothing while it has
/// none: a page per pane must not mean an observer per page.
@MainActor
@Suite struct WindowOcclusionFamilyTests {
    private final class Follower: WindowOcclusionFollowing {
        var changes = 0
        func windowOcclusionDidChange() { changes += 1 }
    }

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func eachNoticeOfAWindowCallsItsFollowersOnceAndNoOtherWindowsFollowers() {
        let center = NotificationCenter()
        let measured = Self.window(), other = Self.window()
        let family = WindowOcclusionFamily.of(measured, center: center)
        let otherFamily = WindowOcclusionFamily.of(other, center: center)
        #expect(WindowOcclusionFamily.of(measured) === family)
        let pages = [Follower(), Follower(), Follower()]
        for page in pages { family.add(page) }
        let elsewhere = Follower()
        otherFamily.add(elsewhere)

        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            center.post(name: name, object: measured)
        }
        #expect(pages.map(\.changes) == [3, 3, 3])
        #expect(elsewhere.changes == 0)
    }

    @Test func itObservesOnlyWhileItHasAFollower() {
        let center = NotificationCenter()
        let family = WindowOcclusionFamily.of(Self.window(), center: center)
        #expect(!family.isObserving)
        let page = Follower()
        family.add(page)
        #expect(family.isObserving)
        #expect(family.followerCount == 1)
        family.remove(page)
        #expect(!family.isObserving)
        #expect(family.followerCount == 0)
    }

    @Test func aGoneFollowerIsNotCalled() throws {
        let center = NotificationCenter()
        let window = Self.window()
        let family = WindowOcclusionFamily.of(window, center: center)
        var page: Follower? = Follower()
        family.add(try #require(page))
        page = nil
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(family.followerCount == 0)
    }
}
