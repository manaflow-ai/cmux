import AppKit
import CmuxNextCompat
import Testing

/// SECURITY (cmux#37286): every capture cmux makes leaves out each of the app's windows with
/// `sharingType = .none` by id (macOS 15.4+ may capture such a window), and a running capture hears
/// each change at once.
@MainActor @Suite(.serialized) struct CaptureExcludedWindowsTests {
    /// The lists an observer heard.
    final class Heard: @unchecked Sendable {
        var lists: [Set<CGWindowID>] = []
    }

    @Test func aWindowThatAsksNotToBeSharedIsLeftOutAndEveryChangeIsHeard() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let id = CGWindowID(window.windowNumber)
        #expect(id > 0)
        #expect(!CaptureExcludedWindows.windowIDs.contains(id), "a shared window stays in")
        let heard = Heard()
        var observation: CaptureExcludedWindows.Observation? = CaptureExcludedWindows.observe { heard.lists.append($0) }
        window.sharingType = .none
        CaptureExcludedWindows.changed()
        #expect(CaptureExcludedWindows.windowIDs.contains(id))
        #expect(heard.lists.count == 1 && heard.lists.last?.contains(id) == true, "heard at once, with the window")
        window.sharingType = .readOnly
        CaptureExcludedWindows.changed()
        #expect(!CaptureExcludedWindows.windowIDs.contains(id))
        #expect(heard.lists.count == 2)
        #expect(observation != nil)
        observation = nil
        CaptureExcludedWindows.changed()
        #expect(heard.lists.count == 2, "a released observation hears nothing")
    }
}
