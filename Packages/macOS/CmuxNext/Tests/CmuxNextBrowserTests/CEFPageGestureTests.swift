import AppKit
@testable import CmuxNextBrowser
import Testing

/// A Chromium page's gestures come from the app's own input events (`CEFLinkClickTracker`): a
/// mouse down, a key down, and the mouse up that ends a click or a drag, as a WebKit page view
/// counts them. Settings > Menus saves a reordered row on the drag's release; with only the down
/// counted, a drag longer than the write's one-second gesture window was refused ("only you can
/// change your menus").
@MainActor
struct CEFPageGestureTests {
    @Test func aMouseUpOnAPageIsTheirGestureAndStillRecordsTheClick() {
        let tracker = CEFLinkClickTracker()
        var gestures: [Int32] = []
        tracker.onGesture = { gestures.append($0) }
        tracker.record(.leftMouseDown, on: 7, button: 0, flags: [], timestamp: 1)
        #expect(gestures == [7], "a press on the page is the person's gesture")
        #expect(tracker.clicks[7] == nil, "a press is no click yet")
        tracker.record(.leftMouseUp, on: 7, button: 0, flags: [.command], timestamp: 2)
        #expect(gestures == [7, 7], "the release that ends a drag is the person's gesture too")
        #expect(tracker.clicks[7]?.timestamp == 2, "the release is still the page's last click")
        tracker.record(.keyDown, on: 7, button: 0, flags: [], timestamp: 3)
        #expect(gestures == [7, 7, 7])
    }

    /// A <select>'s popup is a menu Chromium tracks itself; the pick never reaches the event
    /// monitor, and the click that opened it is spent before the page acts on the choice. Settings
    /// > Agents refused every pick ("set needs a click in the page"). The menu closing is the
    /// person's gesture on the key page window; it grants nothing to a window that is no page's.
    @Test func aChoiceInAPopupChromiumShowsIsTheKeyPagesGesture() {
        let tracker = CEFLinkClickTracker()
        var gestures: [Int32] = []
        tracker.onGesture = { gestures.append($0) }
        let host = NSObject(), page = NSObject(), other = NSObject()
        tracker.targets = { [CEFClickTarget(browser: 9, hostWindow: ObjectIdentifier(host), frame: CGRect(x: 0, y: 0, width: 400, height: 300))] }
        tracker.recordMenuChoice(in: ObjectIdentifier(page), parent: ObjectIdentifier(host), center: CGPoint(x: 200, y: 150))
        #expect(gestures == [9], "the pick in the page's popup is its gesture")
        tracker.recordMenuChoice(in: ObjectIdentifier(host), parent: nil, center: CGPoint(x: 200, y: 150))
        tracker.recordMenuChoice(in: ObjectIdentifier(other), parent: ObjectIdentifier(other), center: CGPoint(x: 200, y: 150))
        #expect(gestures == [9], "a choice while the cmux window or another window is key is no page's gesture")
        let popup = NSMenu(), submenu = NSMenu()
        popup.addItem(withTitle: "read-only", action: nil, keyEquivalent: "").submenu = submenu
        #expect(!CEFLinkClickTracker.inMenuBar(submenu), "a popup's own menu is not the menu bar")
    }
}
