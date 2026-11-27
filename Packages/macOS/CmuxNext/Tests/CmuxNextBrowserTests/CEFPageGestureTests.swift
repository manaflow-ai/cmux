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
}
