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
    @Test func aChoiceInAPopupChromiumShowsIsThePressedPagesGesture() {
        let tracker = CEFLinkClickTracker()
        var gestures: [Int32] = []
        tracker.onGesture = { gestures.append($0) }
        let popup = NSMenu()
        tracker.recordMenuChoice(popup)
        #expect(gestures.isEmpty, "a menu no press on a page opened is no page's gesture")
        // Settings (page 12) sits on the right of a window whose middle is the chat (page 3); the
        // person clicks the Settings select, and its popup closes on a pick.
        tracker.record(.leftMouseDown, on: 3, button: 0, flags: [], timestamp: 1)
        tracker.record(.leftMouseDown, on: 12, button: 0, flags: [], timestamp: 2)
        gestures = []
        tracker.recordMenuChoice(popup)
        #expect(gestures == [12], "the pick counts for the page that was clicked, not the window's middle")
        tracker.forget(opener: 12)
        tracker.recordMenuChoice(popup)
        #expect(gestures == [12], "a closed page's press grants nothing")
        let submenu = NSMenu()
        popup.addItem(withTitle: "read-only", action: nil, keyEquivalent: "").submenu = submenu
        #expect(!CEFLinkClickTracker.inMenuBar(submenu), "a popup's own menu is not the menu bar")
    }
}
