import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import CmuxNextInputCore
import Testing

/// Swipe Back and Forward hear the app's input tap: one scroll intercept, active only
/// while a gesture over a page goes on or the scroll is in a Chromium page window (a child window over
/// its cmux window), so a scroll anywhere else costs no page search and always goes on.
@MainActor @Suite(.serialized) struct CEFSwipeNavigationTests {
    private static func runtime(root: URL) throws -> CEFRuntime {
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        return CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
    }

    private static func scroll(window: Int, owner: Int, type: InputEventType = .scrollWheel) -> InputEventRecord {
        InputEventRecord(type: type, timestamp: 1, windowNumber: window, ownerWindowNumber: owner)
    }

    @Test func aScrollIsHeardOnlyInAPageWindowOrDuringAGestureOverAPage() {
        typealias Swipe = CEFSwipeNavigation
        #expect(Swipe.isListening(gestureOver: false, lastPointer: Self.scroll(window: 12, owner: 7)), "a page window over cmux window 7")
        #expect(!Swipe.isListening(gestureOver: false, lastPointer: Self.scroll(window: 7, owner: 7)), "the cmux window itself")
        #expect(!Swipe.isListening(gestureOver: false, lastPointer: Self.scroll(window: 0, owner: 0)), "no window")
        #expect(!Swipe.isListening(gestureOver: false, lastPointer: nil))
        #expect(!Swipe.isListening(gestureOver: false, lastPointer: Self.scroll(window: 12, owner: 7, type: .mouseMoved)),
                "the pointer record is not this scroll")
        // A gesture that began over a page follows the fingers out of it.
        #expect(Swipe.isListening(gestureOver: true, lastPointer: Self.scroll(window: 7, owner: 7)))
        #expect(Swipe.isListening(gestureOver: true, lastPointer: nil))
    }

    @Test func startingIsOneScrollInterceptAndNoMonitor() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-swipe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Self.runtime(root: root)
        let tap = InputEventTap()
        let swipe = CEFSwipeNavigation(runtime: runtime)
        #expect(!swipe.isStarted)
        swipe.start(input: tap)
        swipe.start(input: tap)
        #expect(swipe.isStarted)
        #expect(tap.subscriberCount(.scroll, stage: .intercept) == 1)
        for eventClass in InputEventClass.allCases where eventClass != .scroll {
            #expect(tap.subscriberCount(eventClass, stage: .intercept) == 0)
            #expect(tap.subscriberCount(eventClass, stage: .observe) == 0)
        }
        #expect(tap.globalMonitorCount == 0)
    }

    /// A host (cmux) window holding a page window, and swipes whose page is the page window's tab.
    @MainActor final class Harness {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-swipe-\(UUID().uuidString)", directoryHint: .isDirectory)
        let runtime: CEFRuntime
        let tap = InputEventTap()
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let page = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 400, height: 300), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let pane: CEFPaneHost
        let tab: CEFTab
        private(set) var swipe: CEFSwipeNavigation?
        /// The scrolls the swipe looked a page up for: its handler ran on a gesture's first scroll.
        var located = 0

        init() throws {
            runtime = try CEFSwipeNavigationTests.runtime(root: root)
            pane = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            tab = CEFTab(id: .random(), profile: .default, host: pane, runtime: runtime)
            for window in [host, page] {
                window.isReleasedWhenClosed = false
                window.orderFrontRegardless()
            }
            host.addChildWindow(page, ordered: .above)
            let swipe = CEFSwipeNavigation(enabled: { true }) { [weak self] event in
                guard let self else { return nil }
                located += 1
                guard event.window === page else { return nil }
                return CEFSwipeNavigation.Target(tab: tab, host: pane.hostView, point: CGPoint(x: 20, y: 20))
            }
            swipe.start(input: tap)
            self.swipe = swipe
        }

        func close() {
            host.removeChildWindow(page)
            for window in [page, host] { window.orderOut(nil) }
            try? FileManager.default.removeItem(at: root)
        }

        /// A trackpad scroll in `window` with gesture phase `phase` (1 began, 2 changed, 4 ended),
        /// addressed as the window server addresses a real one.
        func scroll(phase: Int64, in window: NSWindow) throws -> NSEvent {
            let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -4, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: -4)
            let screen = window.convertPoint(toScreen: CGPoint(x: 20, y: 20))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            let event = try #require(NSEvent(cgEvent: cg))
            try #require(event.window === window)
            return event
        }

        /// Dispatches `event` through the tap's stages, as the application object does.
        @discardableResult
        func dispatch(_ event: NSEvent) -> InputEventTap.InterceptResult {
            var result = InputEventTap.InterceptResult.pass
            tap.dispatching {
                tap.deliverObserve(event)
                result = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
            return result
        }
    }

    @Test func aGestureBeganInAPageWindowIsHandledAndItsEndStopsTheListening() throws {
        let harness = try Harness()
        defer { harness.close() }
        let swipe = try #require(harness.swipe)
        #expect(harness.dispatch(try harness.scroll(phase: 1, in: harness.page)) == .pass, "the page keeps the gesture until it answers")
        #expect(harness.located == 1, "the handler ran on the page window's first scroll")
        #expect(swipe.gesture.phase == .pending)
        #expect(swipe.isFollowingGesture)

        harness.dispatch(try harness.scroll(phase: 4, in: harness.page))
        #expect(swipe.gesture.phase == .idle)
        #expect(!swipe.isFollowingGesture, "the ended gesture no longer follows the fingers")

        // The next gesture, in the cmux window itself, is not heard: no page is looked up for it.
        harness.dispatch(try harness.scroll(phase: 1, in: harness.host))
        harness.dispatch(try harness.scroll(phase: 2, in: harness.host))
        #expect(harness.located == 1)
        #expect(swipe.gesture.phase == .idle)
    }

    @Test func aGestureBeganInTheCmuxWindowIsNeverHandled() throws {
        let harness = try Harness()
        defer { harness.close() }
        let swipe = try #require(harness.swipe)
        #expect(harness.dispatch(try harness.scroll(phase: 1, in: harness.host)) == .pass)
        #expect(harness.located == 0, "the predicate kept the scroll from the handler")
        #expect(swipe.gesture.phase == .idle)
        #expect(!swipe.isFollowingGesture)
    }

    @Test func startingWithASecondTapMovesTheSubscription() throws {
        let harness = try Harness()
        defer { harness.close() }
        let swipe = try #require(harness.swipe)
        let second = InputEventTap()
        swipe.start(input: second)
        #expect(harness.tap.subscriberCount(.scroll, stage: .intercept) == 0)
        #expect(second.subscriberCount(.scroll, stage: .intercept) == 1)
        harness.dispatch(try harness.scroll(phase: 1, in: harness.page))
        #expect(harness.located == 0, "the first tap is no longer heard")
    }
}
