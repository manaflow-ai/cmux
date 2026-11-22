import AppKit
@testable import CmuxNextApp
import Testing

/// Window actions act on the key window, else the frontmost cmux window
/// (nxdog47: Zoom hit the first window; Select Next Window did nothing; Close
/// All Windows left both windows open).
@MainActor @Suite(.serialized) struct WindowTargetingTests {
    static func window(closable: Bool = true) -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 80), styleMask: closable ? [.titled, .closable] : [.titled],
                 backing: .buffered, defer: true)
    }

    @Test func theTargetIsTheKeyWindowElseTheFrontmostShell() {
        let first = Self.window(), second = Self.window(), panel = Self.window()
        #expect(WindowTargeting(keyWindow: first, ordered: [second, first], shells: [first, second]).target === first)
        #expect(WindowTargeting(keyWindow: panel, ordered: [panel, second, first], shells: [first, second]).target === second)
        #expect(WindowTargeting(keyWindow: nil, ordered: [], shells: [first, second]).target === first)
    }

    @Test func cyclingWalksFrontToBackAndWraps() {
        let a = Self.window(), b = Self.window(), c = Self.window()
        let targeting = WindowTargeting(keyWindow: nil, ordered: [b, c, a], shells: [a, b, c])
        #expect(targeting.cycled(1) === c)
        #expect(targeting.cycled(-1) === a)
        #expect(WindowTargeting(keyWindow: nil, ordered: [a], shells: [a]).cycled(1) == nil, "one window: nothing to select")
    }

    final class Refuses: NSObject, NSWindowDelegate {
        func windowShouldClose(_ sender: NSWindow) -> Bool { false }
    }

    @Test func closeClosesAWindowWithoutACloseButtonAndAsksItsDelegate() {
        let window = Self.window(closable: false)
        window.isReleasedWhenClosed = false
        var closed = 0
        let token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        let refuses = Refuses()
        window.delegate = refuses
        WindowTargeting.close(window)
        #expect(closed == 0, "the delegate refused")
        window.delegate = nil
        WindowTargeting.close(window)
        #expect(closed == 1)
    }
}
