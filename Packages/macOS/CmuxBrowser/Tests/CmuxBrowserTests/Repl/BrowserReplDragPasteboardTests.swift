import AppKit
import Testing

@testable import CmuxBrowser

extension BrowserReplPasteboardTests {
    /// An automated HTML5 drag carries the page's drag data from WebKit's
    /// drag start to the drop the driver plays. That data must never sit on
    /// the system's named drag pasteboard, which every process of the user
    /// can read and overwrite while the driver waits for WebKit, and two
    /// drags (two sessions) must never share a pasteboard.
    ///
    /// Nested in the pasteboard suite: the drag window uses the same
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

        private static let drag = NSPasteboard.Name.drag.rawValue

        /// While a drag's window is open, WebKit's lookups of the drag
        /// pasteboard get the drag's own; other code, and WebKit once the
        /// drag started, get the system's.
        @Test func webKitsDragPasteboardIsTheDragsOwnOnlyWhileItsWindowIsOpen() async {
            let capture = BrowserAutomationDragCapture()
            defer { capture.finish() }
            let redirect = BrowserReplDragPasteboardRedirect.shared
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil)
            #expect(await capture.openPasteboardWindow())
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) === capture.pasteboard)
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: false) == nil, "a lookup by other code got the drag's pasteboard")
            #expect(NSPasteboard(name: .drag) !== capture.pasteboard)
            #expect(
                redirect.redirectTarget(forLookupOf: NSPasteboard.Name.general.rawValue, fromWebKit: true) == nil,
                "a drag's window redirected the general pasteboard"
            )
            // WebKit writes the drag data, then asks AppKit for the session.
            capture.begin()
            #expect(capture.didBegin)
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil, "the drag's window outlived the drag's start")
        }

        /// Two sessions' drags never share a window: the second waits for
        /// the first, and fails if the first does not close in time.
        @Test func aSecondDragWaitsForTheFirstDragsWindow() async {
            let first = BrowserAutomationDragCapture()
            let second = BrowserAutomationDragCapture()
            defer {
                first.finish()
                second.finish()
            }
            let redirect = BrowserReplDragPasteboardRedirect.shared
            let clock = ManualClock()
            #expect(await redirect.openDragWindow(first.pasteboard, timeout: .seconds(5), clock: clock))
            let waiting = Task { @MainActor in
                await redirect.openDragWindow(second.pasteboard, timeout: .seconds(5), clock: clock)
            }
            await clock.waitForSleepers(2)
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) === first.pasteboard)
            first.closePasteboardWindow()
            #expect(await waiting.value, "the second drag did not get the window once the first closed it")
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) === second.pasteboard)
            second.closePasteboardWindow()

            #expect(await redirect.openDragWindow(first.pasteboard, timeout: .seconds(5), clock: clock))
            let refused = Task { @MainActor in
                await redirect.openDragWindow(second.pasteboard, timeout: .seconds(5), clock: clock)
            }
            await clock.waitForSleepers(2)
            clock.advance(by: .seconds(5))
            #expect(await refused.value == false, "a drag opened its window while another drag's was open")
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil, "a window outlived its bound")
        }

        /// A finished capture's pasteboard is closed off, emptied and
        /// released, and the capture cannot open its window again.
        @Test func aFinishedCaptureReleasesItsPasteboard() async {
            let capture = BrowserAutomationDragCapture()
            #expect(await capture.openPasteboardWindow())
            capture.pasteboard.clearContents()
            capture.pasteboard.setString("drag data", forType: .string)
            capture.finish()
            #expect(BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil)
            #expect(capture.pasteboard.types?.isEmpty ?? true)
            #expect(await !capture.openPasteboardWindow())
        }
    }
}
