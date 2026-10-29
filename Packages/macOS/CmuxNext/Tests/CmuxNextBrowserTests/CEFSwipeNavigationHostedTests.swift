#if DEBUG || CMUX_BENCH_HOOKS
import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import Testing

/// Swipes over a hosted page: the page view hands each scroll to the swipe first, and
/// on a host that acks wheels the gesture decides from the WHEEL_ACKs of its own wheels, with no page probe
/// (no control request); acks of earlier wheels or of another page are not its own. A host without acks is
/// probed as in process.
@MainActor @Suite(.serialized) struct CEFSwipeNavigationHostedTests {
    @MainActor final class Harness {
        static let browser: Int32 = 7
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-swipe-hosted-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime: CEFRuntime
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let pane: CEFPaneHost
        let tab: CEFTab
        let page: ChromiumHostPageView
        let swipe: CEFSwipeNavigation
        let tap = InputEventTap()
        var located = 0
        /// The wheel frames the page view sent to the host, by input seq.
        private(set) var sentSeqs: [UInt32] = []
        private var nextSeq: UInt32 = 10

        init(acksWheels: Bool) throws {
            let nothing: @convention(c) () -> Int = { 0 }
            let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
            runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
            pane = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            tab = CEFTab(id: .random(), profile: .default, host: pane, runtime: runtime)
            tab.browserID = Self.browser
            page = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), inputTarget: .view)
            var locate: (NSEvent) -> CEFSwipeNavigation.Target? = { _ in nil }
            swipe = CEFSwipeNavigation(enabled: { true }, locate: { locate($0) }, acksWheels: { acksWheels })
            locate = { [unowned self] _ in
                located += 1
                return nil
            }
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(pane.hostView)
            pane.hostView.frame = window.contentView?.bounds ?? .zero
            pane.hostView.addSubview(page)
            page.sink = { [unowned self] frame in
                guard frame.kind == .wheel else { return nil }
                nextSeq += 1
                sentSeqs.append(nextSeq)
                return ChromiumHostInputReceipt(browser: Self.browser, seq: nextSeq)
            }
            page.wheelGesture = { [unowned self] event in swipe.handleHosted(event, tab: tab, page: page) }
            swipe.start(input: tap)
        }

        func close() {
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: root)
        }

        /// A trackpad scroll over the page with gesture phase `phase` (1 began, 2 changed, 4 ended; 0 a mouse
        /// wheel), as the window server addresses one to the page view's window.
        func scroll(phase: Int64, dx: Double = -4) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                                          wheel2: Int32(dx), wheel3: 0))
            if phase != 0 {
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            }
            let screen = window.convertPoint(toScreen: CGPoint(x: 40, y: 40))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            return try #require(NSEvent(cgEvent: cg))
        }

        /// `event` through the app's input tap (the intercept), then to the page view, as AppKit delivers it.
        func deliver(_ event: NSEvent) {
            var result = InputEventTap.InterceptResult.pass
            tap.dispatching {
                tap.deliverObserve(event)
                result = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
            if result == .pass { page.scrollWheel(with: event) }
        }

        func ack(seq: UInt32, consumed: Bool, browser: Int32 = Harness.browser) {
            let ack = consumed
                ? BrowserWheelAck(seq: seq, scrollUpdate: true, consumed: true, consumedX: 4)
                : BrowserWheelAck(seq: seq, scrollUpdate: true, consumed: false, overscroll: .init(x: -4, behaviorX: .auto))
            // CEFPaneHost.pageViewChanged hands a WHEEL_ACK of its page to the runtime's swipe the same way.
            swipe.wheelAcked(ack, browser: browser)
        }
    }

    @Test func aHostedGestureDecidesFromItsOwnAcksAndProbesNothing() throws {
        let harness = try Harness(acksWheels: true)
        defer { harness.close() }
        let swipe = harness.swipe
        // A mouse wheel before the gesture: no phase, so the swipe passes it and the page gets it.
        harness.deliver(try harness.scroll(phase: 0))
        #expect(harness.sentSeqs == [11])

        harness.deliver(try harness.scroll(phase: 1))
        #expect(harness.sentSeqs == [11, 12], "the gesture's first wheel still goes to the page")
        #expect(swipe.gesture.phase == .pending)
        #expect(swipe.isFollowingGesture)
        #expect(harness.located == 0, "the intercept does not handle a hosted page's gesture as well")

        // Only the page's acks of the gesture's own wheels count.
        harness.ack(seq: 11, consumed: true)
        harness.ack(seq: 12, consumed: true, browser: Harness.browser + 1)
        #expect(swipe.stats.acks == 0, "an earlier wheel's ack and another page's are not this gesture's")
        #expect(swipe.gesture.phase == .pending)

        harness.ack(seq: 12, consumed: true)
        #expect(swipe.stats.acks == 1)
        #expect(swipe.gesture.phase == .declined, "the page scrolled sideways for the first update: it keeps the gesture")
        harness.deliver(try harness.scroll(phase: 2))
        harness.deliver(try harness.scroll(phase: 2))
        #expect(harness.sentSeqs == [11, 12, 13, 14], "a declined gesture's wheels go to the page")
        harness.deliver(try harness.scroll(phase: 4))
        #expect(!swipe.isFollowingGesture)
        #expect(swipe.stats.probes == 0, "no probe: a hosted gesture sends the host no control request")
        #expect(swipe.stats.gestures == 1)
    }

    @Test func anUnconsumedFirstUpdateLeavesTheGestureToTheSwipe() throws {
        let harness = try Harness(acksWheels: true)
        defer { harness.close() }
        harness.deliver(try harness.scroll(phase: 1, dx: -2))
        harness.ack(seq: 11, consumed: false)
        #expect(harness.swipe.gesture.phase == .pending, "both answers are in; the slop decides the direction")
        #expect(harness.swipe.stats.probes == 0)
    }

    /// The host names each ack by its own wheel's seq (`WheelAcks`, several wheels in flight): a consumed ack of a
    /// wheel sent before the gesture that comes after its began wheel went out is not the gesture's first answer.
    @Test func aLateConsumedAckOfAnEarlierWheelDoesNotDeclineTheGesture() throws {
        let harness = try Harness(acksWheels: true)
        defer { harness.close() }
        let swipe = harness.swipe
        harness.deliver(try harness.scroll(phase: 0))
        harness.deliver(try harness.scroll(phase: 1))
        #expect(harness.sentSeqs == [11, 12], "the earlier wheel and the began wheel are both in flight")

        harness.ack(seq: 11, consumed: true)
        #expect(swipe.gesture.phase == .pending, "the earlier wheel's consumed ack is not this gesture's")
        harness.ack(seq: 12, consumed: false)
        #expect(swipe.gesture.phase == .pending, "the began wheel's own unconsumed ack leaves the gesture to the swipe")
        #expect(swipe.stats.acks == 1)
        #expect(swipe.stats.probes == 0)
    }

    @Test func aHostWithoutAcksIsProbed() throws {
        let harness = try Harness(acksWheels: false)
        defer { harness.close() }
        harness.deliver(try harness.scroll(phase: 1))
        #expect(harness.swipe.stats.probes == 1)
        harness.ack(seq: 11, consumed: true)
        #expect(harness.swipe.stats.acks == 0, "a probing gesture takes no acks")
        #expect(harness.swipe.gesture.phase == .pending)
    }
}
#endif
