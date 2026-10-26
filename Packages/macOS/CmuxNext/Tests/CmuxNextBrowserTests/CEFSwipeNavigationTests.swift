import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import CmuxNextInputCore
import Testing

/// Swipe Back and Forward hear the app's input tap (p04-input-018): one scroll intercept, active only
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

    @Test func aScrollOutsideAPageWindowGoesOn() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-swipe-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try Self.runtime(root: root)
        let tap = InputEventTap()
        let swipe = CEFSwipeNavigation(runtime: runtime)
        swipe.start(input: tap)
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -40, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cg))
        var result = InputEventTap.InterceptResult.consume
        tap.dispatching {
            tap.deliverObserve(event)
            result = tap.deliverIntercepts(event)
        }
        #expect(result == .pass)
    }
}
