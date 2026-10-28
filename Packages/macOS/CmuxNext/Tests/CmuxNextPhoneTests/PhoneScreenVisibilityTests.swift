import AppKit
@testable import CmuxNextPhone
import CmuxNextWakeups
import Testing

/// p06-scheduler-342 (R-vis, R-notif): the phone's screen follows its tab's visibility node, with no window
/// occlusion notice or ancestor walk of its own. It is on screen only in a window while the node is visible, and
/// each flip of the node reports once, so a hidden tab stops its frames.
@MainActor
struct PhoneScreenVisibilityTests {
    @Test func theScreenReportsEachFlipOfItsTabsNodeOnce() {
        let node = VisibilityNode(root: "test.phone.tab", own: .visible)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PhoneScreenView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        var seen: [Bool] = []
        view.onVisibilityChange = { seen.append($0) }
        view.follow(node)
        #expect(!view.isOnScreen, "a screen in no window is on screen")

        window.contentView?.addSubview(view)
        #expect(view.isOnScreen, "a screen in a window under a visible tab is not on screen")
        node.set(.hidden)
        #expect(!view.isOnScreen, "the screen of a hidden tab is on screen")
        node.set(.hidden)
        node.set(.visible)
        #expect(seen == [false, true, false, true], "each change reports once: \(seen)")

        view.close()
        node.set(.hidden)
        #expect(seen == [false, true, false, true], "a closed screen still follows its tab")
    }
}
