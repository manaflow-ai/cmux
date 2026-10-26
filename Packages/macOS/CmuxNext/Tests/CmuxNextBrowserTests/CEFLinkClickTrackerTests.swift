import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import Testing

/// Link clicks on Chromium pages hear the app's input tap (p04-input-018): one observer of buttons and
/// keys, never an intercept, that records a page's mouse-up with its modifiers and reports a press on
/// a page as a fresh user gesture. A page draws in its own child window over its cmux window.
@MainActor @Suite(.serialized) struct CEFLinkClickTrackerTests {
    @MainActor final class Harness {
        let tap = InputEventTap()
        let tracker = CEFLinkClickTracker()
        let host = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 600, height: 400), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        let page = NSWindow(contentRect: NSRect(x: 150, y: 150, width: 400, height: 300), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        var gestures: [Int32] = []
        var targetReads = 0

        init() {
            for window in [host, page] {
                window.isReleasedWhenClosed = false
                window.orderFrontRegardless()
            }
            host.addChildWindow(page, ordered: .above)
            tracker.onGesture = { [weak self] in self?.gestures.append($0) }
            tracker.startRecordingClicks(input: tap) { [weak self] in
                guard let self else { return [] }
                targetReads += 1
                return [CEFClickTarget(browser: 7, hostWindow: ObjectIdentifier(host), frame: page.frame)]
            }
        }

        func close() {
            host.removeChildWindow(page)
            for window in [page, host] { window.orderOut(nil) }
        }

        /// Dispatches `event` through the tap's three stages, as the application object does.
        func dispatch(_ event: NSEvent) {
            tap.dispatching {
                tap.deliverObserve(event)
                _ = tap.deliverIntercepts(event)
                tap.deliverAfterDispatch(event)
            }
        }

        func mouse(_ type: NSEvent.EventType, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 20, y: 20), modifierFlags: flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }

        func key(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        }
    }

    @Test func recordingIsOneObserverOfButtonsAndKeysAndNoMonitor() {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.tracker.isRecording)
        #expect(harness.tap.subscriberCount(.button, stage: .observe) == 1)
        #expect(harness.tap.subscriberCount(.key, stage: .observe) == 1)
        for eventClass in InputEventClass.allCases {
            #expect(harness.tap.subscriberCount(eventClass, stage: .intercept) == 0, "the tracker never consumes")
        }
        #expect(harness.tap.globalMonitorCount == 0)
        // A second start (every tab registration asks) adds nothing.
        harness.tracker.startRecordingClicks(input: harness.tap) { [] }
        #expect(harness.tap.subscriberCount(.button, stage: .observe) == 1)
    }

    @Test func aMouseUpOnAPageRecordsItsGestureAndAPressReportsAUserGesture() throws {
        let harness = Harness()
        defer { harness.close() }
        harness.dispatch(try harness.mouse(.leftMouseDown, in: harness.page))
        #expect(harness.gestures == [7])
        #expect(harness.tracker.clicks[7] == nil, "a press is a gesture, not a click")

        harness.dispatch(try harness.mouse(.leftMouseUp, in: harness.page, flags: .command))
        #expect(harness.tracker.clicks[7]?.gesture == .cmd)
        harness.dispatch(try harness.key(.keyDown, in: harness.page))
        #expect(harness.gestures == [7, 7])
    }

    @Test func eventsTheTrackerDoesNotReadAndClicksOutsideAPageRecordNothing() throws {
        let harness = Harness()
        defer { harness.close() }
        // A right mouse-up and a key-up are neither a click nor a fresh gesture: no target is even read.
        harness.dispatch(try harness.mouse(.rightMouseUp, in: harness.page))
        harness.dispatch(try harness.key(.keyUp, in: harness.page))
        #expect(harness.targetReads == 0)
        // The cmux window itself (strip, sidebar, omnibar) is no page.
        harness.dispatch(try harness.mouse(.leftMouseUp, in: harness.host))
        #expect(harness.tracker.clicks.isEmpty && harness.gestures.isEmpty)
    }

    @Test func theReadEventTypesAreTheOldMonitorsMask() {
        let read: [NSEvent.EventType] = [.leftMouseUp, .otherMouseUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        for type in read { #expect(CEFLinkClickTracker.records(type)) }
        let skipped: [NSEvent.EventType] = [.rightMouseUp, .keyUp, .flagsChanged, .mouseMoved, .scrollWheel]
        for type in skipped { #expect(!CEFLinkClickTracker.records(type)) }
    }

    @Test func theRuntimeKeepsTheFirstInputTap() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        let first = InputEventTap()
        #expect(runtime.input == nil)
        runtime.attachInput(first)
        runtime.attachInput(InputEventTap())
        #expect(runtime.input === first)
    }
}
