import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
@testable import CmuxNextInput
import CmuxNextInputCore
import CmuxNextSignposts
import CmuxNextWakeups
import Testing

/// The app's input targets for a host-mode Chromium page: its page view takes text input, yet its
/// keys and clicks are the page's, so its host's presentation report finds their slots.
@MainActor @Suite(.serialized)
struct AppInputTargetsTests {
    /// A commit boundary the test fires.
    @MainActor
    final class Boundary: InputTurnBoundary {
        private var handler: (@MainActor (CommitBoundary.Outcome) -> Void)?
        private(set) var isArmed = false

        func start(_ handler: @escaping @MainActor (CommitBoundary.Outcome) -> Void) { self.handler = handler }
        func arm() { isArmed = true }

        func commit() {
            guard isArmed else { return }
            isArmed = false
            handler?(.committed)
        }
    }

    /// A presentation clock that never answers: a host-mode page's slot needs none.
    @MainActor
    final class SilentPresentation: InputPresentationEstimating {
        private(set) var asked = 0
        func holdLinkForInput(in window: NSWindow?) {}
        func presented(committedAt nanos: UInt64, in window: NSWindow?, _ resolve: @escaping PresentationClock.Resolve) {
            asked += 1
        }
    }

    /// A cmux window whose content holds a host-mode page view on its left half.
    private func pageWindow() -> (NSWindow, ChromiumHostPageView) {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
        content.addSubview(page)
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        return (window, page)
    }

    @Test("A host-mode page view is a Chromium page for its keys and for a pointer over it, not a text view")
    func hostPageViewIsAChromiumPage() throws {
        let classifier = AppServices.inputTargets(agentPaneOwnsPage: { _ in false })
        let (window, page) = pageWindow()
        defer { window.close() }
        #expect(window.makeFirstResponder(page))
        #expect(classifier.keyTarget(in: window) == .chromiumPage)
        let over = page.convert(NSPoint(x: 100, y: 150), to: nil)
        let hit = try #require(InputTargetClassifier.view(at: over, in: window))
        #expect(hit === page)
        #expect(classifier.classify(view: hit, in: window) == .chromiumPage)
        let text = NSTextView(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
        window.contentView?.addSubview(text)
        #expect(classifier.classify(view: text, in: window) == .textView, "other text input stays a text view")
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test("A click on a host-mode page opens a page slot that its host's report by the click's t0 closes as hostFeedback")
    func hostReportClosesTheClicksSlot() throws {
        let boundary = Boundary()
        let presentation = SilentPresentation()
        var emitted: [InputLatencySlot] = []
        let now: UInt64 = 6_000_000_000_000
        let tracker = InputLatencyTracker(table: InputLatencySlotTable(), ring: InputLatencyRing(),
                                          presentation: presentation, boundary: boundary,
                                          emit: { emitted.append($0) }, batchSink: nil, now: { now })
        tracker.pagesReportPresentation = true  // the host's ready announced its reports
        let dispatch = InputLatencyDispatch(tracker: tracker,
                                            classifier: AppServices.inputTargets(agentPaneOwnsPage: { _ in false }),
                                            windowChanged: { _ in false })
        let (window, page) = pageWindow()
        defer { window.close() }
        var sent: [ChromiumHostFrame] = []
        page.sink = { frame in
            sent.append(frame)
            return nil
        }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: page.convert(NSPoint(x: 100, y: 150), to: nil),
                                                    modifierFlags: [], timestamp: 5_000, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        let slot = try #require(dispatch.willDeliver(click, in: window, to: page))
        page.mouseDown(with: click)
        dispatch.didDispatch(slot, layoutTookScroll: false)
        #expect(slot.target == .chromiumPage)
        boundary.commit()
        #expect(emitted.isEmpty, "the page's frame comes after the commit")

        let frame = try #require(sent.first { $0.kind == .mouse })
        let shown = now + 8_000_000
        #expect(tracker.hostPresented(eventNanos: frame.t0, at: shown))
        let closed = try #require(emitted.first)
        #expect(closed.target == .chromiumPage && closed.presentationSource == .hostFeedback && closed.presented == shown)
        #expect(tracker.unmatchedHostPresentations == 0 && presentation.asked == 0)
    }
    #endif
}
