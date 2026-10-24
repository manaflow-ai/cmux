import AppKit
@testable import CmuxNextDesign
import Testing

/// PATTERNS.md P3: a window's occlusion is observed once per window (``WindowOcclusionFamily``),
/// and only its followers are called, only when the state flips. A follower that leaves (or goes
/// away) is not called, and a family with no follower observes nothing.
@MainActor
@Suite struct WindowOcclusionFamilyTests {
    /// The window's occlusion as a test drives it.
    @MainActor
    final class Screen {
        let center = NotificationCenter()
        var visible = true

        func family(_ window: NSWindow) -> WindowOcclusionFamily {
            WindowOcclusionFamily.of(window, center: center, onScreen: { [unowned self] _ in self.visible })
        }

        func set(_ visible: Bool, _ window: NSWindow) {
            self.visible = visible
            center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
    }

    private final class Owner {}

    private static func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func oneFamilyPerWindowCallsItsFollowersOnlyOnAFlip() {
        let screen = Screen()
        let window = Self.window()
        let family = screen.family(window)
        #expect(WindowOcclusionFamily.of(window) === family)
        #expect(!family.isObserving)
        let a = Owner(), b = Owner()
        var calls: [String] = []
        family.follow(a) { calls.append("a \($0)") }
        family.follow(b) { calls.append("b \($0)") }
        #expect(family.isObserving)

        screen.set(true, window)
        #expect(calls.isEmpty, "no flip, no call")
        screen.set(false, window)
        #expect(calls.sorted() == ["a false", "b false"])
        #expect(family.isVisible == false)
    }

    @Test func aFollowerThatLeavesIsNotCalledAndTheLastStopsTheObservation() {
        let screen = Screen()
        let window = Self.window()
        let family = screen.family(window)
        let a = Owner()
        var calls = 0
        family.follow(a) { _ in calls += 1 }
        family.unfollow(a)
        #expect(!family.isObserving)
        screen.set(false, window)
        #expect(calls == 0)

        var gone: Owner? = Owner()
        family.follow(gone!) { _ in calls += 1 }
        gone = nil
        screen.set(true, window)
        #expect(calls == 0, "a follower that went away is not called")
        #expect(family.followerCount == 0)
        #expect(!family.isObserving)
    }

    /// A family that observed nothing for a while reads the window again when a follower comes.
    @Test func aNewFollowerReadsTheWindowNow() {
        let screen = Screen()
        let window = Self.window()
        let family = screen.family(window)
        screen.visible = false
        family.follow(Owner()) { _ in }
        #expect(family.isVisible == false)
    }
}
