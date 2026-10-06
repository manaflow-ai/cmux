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
                first.closePasteboardWindow()
                second.closePasteboardWindow()
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
            // Past its bound, the first window no longer hands out the
            // drag's pasteboard, yet WebKit may still be handling the event
            // that opened it: its lookups get a private discard until the
            // driver closes the window, never the system's.
            await Self.untilLookup(isNot: first.pasteboard)
            Self.expectPrivateDiscard(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true), not: first.pasteboard)
            first.closePasteboardWindow()
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil, "a closed window kept redirecting")
        }

        /// Yields until WebKit's lookup of the drag pasteboard no longer
        /// gets `pasteboard` (the window's bound task ran), at most 1000 turns.
        private static func untilLookup(isNot pasteboard: NSPasteboard) async {
            for _ in 0..<1000 {
                guard BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: drag, fromWebKit: true) === pasteboard else { return }
                await Task.yield()
            }
        }

        /// `late` is a private pasteboard (not the system's named drag
        /// pasteboard, not the drag's own) that keeps nothing written to it.
        private static func expectPrivateDiscard(_ late: NSPasteboard?, not own: NSPasteboard, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(late != nil, "a late WebKit lookup got the system's drag pasteboard", sourceLocation: sourceLocation)
            guard let late else { return }
            #expect(late !== own, "a late WebKit lookup still got the drag's pasteboard", sourceLocation: sourceLocation)
            #expect(late.name != .drag, "a late WebKit lookup got the system's drag pasteboard", sourceLocation: sourceLocation)
            late.clearContents()
            late.setString("late drag data", forType: .string)
            let again = BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: drag, fromWebKit: true)
            #expect(again?.string(forType: .string) == nil, "the discard kept a late write", sourceLocation: sourceLocation)
        }

        /// A page whose drag handler runs past the window's bound: WebKit
        /// writes the drag data after the bound, so the write must go to a
        /// private discard, no other drag may open its window meanwhile,
        /// and the drag WebKit then starts is known to carry no data.
        @Test func aDragStartedPastItsWindowsBoundWritesOnlyToADiscard() async {
            let capture = BrowserAutomationDragCapture()
            let other = BrowserAutomationDragCapture()
            defer {
                capture.closePasteboardWindow()
                other.closePasteboardWindow()
                capture.finish()
                other.finish()
            }
            let redirect = BrowserReplDragPasteboardRedirect.shared
            let clock = ManualClock()
            #expect(await redirect.openDragWindow(capture.pasteboard, timeout: .seconds(5), clock: clock))
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(5))
            await Self.untilLookup(isNot: capture.pasteboard)
            Self.expectPrivateDiscard(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true), not: capture.pasteboard)

            let waiting = Task { @MainActor in
                await redirect.openDragWindow(other.pasteboard, timeout: .seconds(5), clock: clock)
            }
            await clock.waitForSleepers(1)
            clock.advance(by: .seconds(5))
            #expect(await waiting.value == false, "another drag opened its window while a late event could still write")

            // WebKit wrote the data (to the discard), then starts the drag.
            capture.begin()
            #expect(capture.didBegin)
            #expect(redirect.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil)
        }

        /// The tab's drag state is reset (the capture is cleared) while
        /// WebKit still handles the event that opened the window: lookups
        /// stay private until the driver closes the window.
        @Test func aCaptureClearedWhileItsEventRunsKeepsLateWritesPrivate() async {
            let capture = BrowserAutomationDragCapture()
            defer { capture.closePasteboardWindow() }
            #expect(await capture.openPasteboardWindow())
            capture.finish()
            Self.expectPrivateDiscard(
                BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: Self.drag, fromWebKit: true),
                not: capture.pasteboard
            )
            // The driver closes the window once WebKit handled the event.
            capture.closePasteboardWindow()
            #expect(BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil)
        }

        /// A finished capture's pasteboard is closed off, emptied and
        /// released, and the capture cannot open its window again.
        @Test func aFinishedCaptureReleasesItsPasteboard() async {
            let capture = BrowserAutomationDragCapture()
            #expect(await capture.openPasteboardWindow())
            capture.pasteboard.clearContents()
            capture.pasteboard.setString("drag data", forType: .string)
            capture.finish()
            capture.closePasteboardWindow()
            #expect(BrowserReplDragPasteboardRedirect.shared.redirectTarget(forLookupOf: Self.drag, fromWebKit: true) == nil)
            #expect(capture.pasteboard.types?.isEmpty ?? true)
            #expect(await !capture.openPasteboardWindow())
        }
    }
}
