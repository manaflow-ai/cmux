import AppKit
@testable import CmuxNextDesign
import Testing

/// A window's ``WindowNotices`` observes its main and occlusion notices once for all of its
/// followers, calls each follower only for the notices it asked for, and observes only while
/// something follows the window. Each test posts on its own `NotificationCenter`.
@MainActor
@Suite
struct WindowNoticesTests {
    /// A follower that records what it was called for.
    final class Recorder: WindowNoticesFollower {
        var heard: [WindowNotice] = []

        func windowNoticed(_ notice: WindowNotice) { heard.append(notice) }
    }

    /// A follower that is an Objective-C object (an agent pane's probe is an `NSView`).
    final class ViewRecorder: NSView, WindowNoticesFollower {
        var heard: [WindowNotice] = []

        func windowNoticed(_ notice: WindowNotice) { heard.append(notice) }
    }

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func eachFollowerHearsOnlyTheNoticesItAskedFor() {
        _ = NSApplication.shared
        let window = Self.window()
        let center = NotificationCenter()
        let notices = WindowNotices.of(window, center: center)
        let main = Recorder(), occlusion = ViewRecorder(frame: .zero)
        notices.add(main, for: [.becameMain, .resignedMain])
        notices.add(occlusion, for: [.occlusionChanged])
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        center.post(name: NSWindow.didResignMainNotification, object: window)
        // Another window's notices reach neither.
        center.post(name: NSWindow.didBecomeMainNotification, object: Self.window())
        #expect(main.heard == [.becameMain, .resignedMain])
        #expect(occlusion.heard == [.occlusionChanged])
    }

    /// When the last follower is removed, the window is no longer observed; a new follower
    /// observes it again.
    @Test func itObservesOnlyWhileSomethingFollowsTheWindow() {
        _ = NSApplication.shared
        let window = Self.window()
        let center = NotificationCenter()
        let notices = WindowNotices.of(window, center: center)
        let first = Recorder(), second = Recorder()
        #expect(!notices.isObserving)
        notices.add(first, for: [.becameMain])
        notices.add(second, for: [.occlusionChanged])
        #expect(notices.isObserving)
        notices.remove(first)
        #expect(notices.isObserving)
        notices.remove(second)
        #expect(!notices.isObserving)
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(first.heard.isEmpty)
        notices.add(first, for: [.becameMain])
        #expect(notices.isObserving)
    }

    /// A follower released in the same turn (no autorelease pool drains in between) is gone: it
    /// gets no call, and the next notice finds nothing following and ends the observations. Reading
    /// the followers must not keep them alive (an `NSHashTable.allObjects` read autoreleased them
    /// until the pool drained).
    @Test(arguments: [false, true])
    func aFollowerReleasedInTheSameTurnEndsTheObservation(objectiveC: Bool) {
        _ = NSApplication.shared
        let window = Self.window()
        let center = NotificationCenter()
        let notices = WindowNotices.of(window, center: center)
        let kept = Recorder()
        notices.add(kept, for: [.becameMain])
        // Made inside its own pool, so only the reads under test could keep it alive.
        var released: (any WindowNoticesFollower)? = autoreleasepool { () -> any WindowNoticesFollower in
            if objectiveC { return ViewRecorder(frame: .zero) }
            return Recorder()
        }
        weak var gone = released
        if let released { notices.add(released, for: [.becameMain, .occlusionChanged]) }
        // A read of the followers while both live, as a notice or a removal does.
        center.post(name: NSWindow.didBecomeMainNotification, object: window)
        notices.remove(kept)
        #expect(notices.isObserving)
        released = nil
        #expect(gone == nil)
        center.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
        #expect(!notices.isObserving)
    }

    /// Each center gets its own instance for a window, so a follower always observes the center it
    /// names; the same center returns the same instance.
    @Test func eachCenterHasItsOwnInstanceForTheWindow() {
        _ = NSApplication.shared
        let window = Self.window()
        let first = NotificationCenter(), second = NotificationCenter()
        #expect(WindowNotices.of(window, center: first) === WindowNotices.of(window, center: first))
        #expect(WindowNotices.of(window, center: first) !== WindowNotices.of(window, center: second))
        let recorder = Recorder()
        WindowNotices.of(window, center: second).add(recorder, for: [.becameMain])
        first.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(recorder.heard.isEmpty)
        second.post(name: NSWindow.didBecomeMainNotification, object: window)
        #expect(recorder.heard == [.becameMain])
    }
}
