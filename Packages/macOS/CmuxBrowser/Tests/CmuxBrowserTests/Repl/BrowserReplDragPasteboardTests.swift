import AppKit
import Testing

@testable import CmuxBrowser

extension BrowserReplPasteboardRedirectTests {
    /// An automated HTML5 drag carries the page's drag data from WebKit's
    /// drag start to the drop the driver plays. That data must never sit on
    /// the system's named drag pasteboard, which every process of the user
    /// can read and overwrite while the driver waits for WebKit, and two
    /// drags (two sessions) must never share a pasteboard.
    ///
    /// Nested in the redirect suite: the drag window uses the same
    /// process-wide lookup hook.
    @MainActor
    @Suite("Automated drags", .serialized)
    struct AutomatedDrags {
        @Test func eachAutomatedDragHasItsOwnPrivatePasteboard() {
            let first = BrowserAutomationDragCapture()
            let second = BrowserAutomationDragCapture()
            #expect(first.pasteboard.name != .drag, "an automated drag uses the system's drag pasteboard")
            #expect(first.pasteboard.name != second.pasteboard.name, "two automated drags share a pasteboard")
        }
    }
}
