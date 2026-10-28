import AppKit
@testable import CmuxNextBrowser
import CmuxNextInput
import Testing

/// Link clicks on Chromium pages hear the app's input tap: one `.standard` intercept of
/// buttons and keys that always passes, where AppKit's local monitor ran. It records a page's mouse-up
/// with its modifiers and reports a press on a page as a fresh user gesture, but only for input that
/// reaches the page: a shortcut the key router takes or a click an earlier intercept consumes is
/// neither (Chrome's `DownloadRequestLimiter` resets only on input sent to the renderer). A page
/// draws in its own child window over its cmux window.
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
        /// Events an intercept after the tracker heard.
        var heardAfter = 0

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

        /// Dispatches `event` through the tap's three stages, as the application object does
        /// (`CmuxApplication.route`): a key the key router takes (`routerTakes`) reaches no intercept
        /// and no after-dispatch observer.
        func dispatch(_ event: NSEvent, routerTakes: Bool = false) {
            tap.dispatching {
                tap.deliverObserve(event)
                guard !routerTakes else { return }
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

    @Test func recordingIsOneInterceptOfButtonsAndKeysAndNoMonitor() {
        let harness = Harness()
        defer { harness.close() }
        #expect(harness.tracker.isRecording)
        #expect(harness.tap.subscriberCount(.button, stage: .intercept) == 1)
        #expect(harness.tap.subscriberCount(.key, stage: .intercept) == 1)
        for eventClass in InputEventClass.allCases {
            #expect(harness.tap.subscriberCount(eventClass, stage: .observe) == 0, "nothing before the key router")
            #expect(harness.tap.subscriberCount(eventClass, stage: .afterDispatch) == 0)
        }
        #expect(harness.tap.globalMonitorCount == 0)
        // A second start with the same tap (every tab registration asks) adds nothing.
        harness.tracker.startRecordingClicks(input: harness.tap) { [] }
        #expect(harness.tap.subscriberCount(.button, stage: .intercept) == 1)
    }

    @Test func theTrackerNeverConsumes() throws {
        let harness = Harness()
        defer { harness.close() }
        let after = harness.tap.subscribe(class: [.button, .key], phase: .intercept(order: InputEventTap.InterceptOrder(rawValue: 2000))) { _ in
            harness.heardAfter += 1
            return .pass
        }
        harness.dispatch(try harness.mouse(.leftMouseDown, in: harness.page))
        harness.dispatch(try harness.key(.keyDown, in: harness.page))
        #expect(harness.gestures == [7, 7])
        #expect(harness.heardAfter == 2,"an intercept after the tracker still gets every event")
        after.cancel()
    }

    @Test func aKeyTheRouterTakesIsNoGesture() throws {
        let harness = Harness()
        defer { harness.close() }
        // A cmux shortcut (Cmd-T) pressed while a page has focus: the key router takes it, the page never gets it.
        harness.dispatch(try harness.key(.keyDown, in: harness.page), routerTakes: true)
        #expect(harness.gestures.isEmpty, "a shortcut does not reset the page's automatic-download count")
        #expect(harness.targetReads == 0)
    }

    @Test func inputAnEarlierInterceptConsumesIsNoGestureAndNoClick() throws {
        let harness = Harness()
        defer { harness.close() }
        // A modal picker's click over a page, and a key it takes.
        let modal = harness.tap.subscribe(class: [.button, .key], phase: .intercept(order: .modal)) { _ in .consume }
        harness.dispatch(try harness.mouse(.leftMouseDown, in: harness.page))
        harness.dispatch(try harness.key(.keyDown, in: harness.page))
        #expect(harness.gestures.isEmpty)
        // A layout intercept consumes a mouse-up: it is no link click.
        modal.cancel()
        let layout = harness.tap.subscribe(class: .button, phase: .intercept(order: .layout)) { event in
            event.type == .leftMouseUp ? .consume : .pass
        }
        harness.dispatch(try harness.mouse(.leftMouseUp, in: harness.page, flags: .command))
        #expect(harness.tracker.clicks.isEmpty)
        #expect(harness.gestures.isEmpty)
        layout.cancel()
    }

    @Test func startingWithASecondTapMovesTheSubscription() throws {
        let harness = Harness()
        defer { harness.close() }
        let second = InputEventTap()
        harness.tracker.startRecordingClicks(input: second) { [harness] in
            [CEFClickTarget(browser: 7, hostWindow: ObjectIdentifier(harness.host), frame: harness.page.frame)]
        }
        #expect(harness.tap.subscriberCount(.button, stage: .intercept) == 0)
        #expect(second.subscriberCount(.button, stage: .intercept) == 1)
        harness.dispatch(try harness.mouse(.leftMouseDown, in: harness.page))
        #expect(harness.gestures.isEmpty, "the first tap is no longer heard")
        let down = try harness.mouse(.leftMouseDown, in: harness.page)
        second.dispatching { _ = second.deliverIntercepts(down) }
        #expect(harness.gestures == [7], "the second tap's events reach the tracker")
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

    /// A later engine's tap replaces the runtime's: link clicks and swipes that already hear the first
    /// tap move to it, so a second AppServices in one process is not left deaf.
    @Test func theRuntimeHearsTheNewestTap() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cef-input-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let nothing: @convention(c) () -> Int = { 0 }
        let shim = try CEFShimLibrary.resolving { _ in unsafeBitCast(nothing, to: UnsafeMutableRawPointer.self) }
        let runtime = CEFRuntime(shim: shim, storage: CEFProfileStorage(root: root))
        let first = InputEventTap()
        let second = InputEventTap()
        #expect(runtime.input == nil)
        runtime.attachInput(first)
        // A tab registered: link clicks and swipes hear the first tap.
        runtime.windowRequests.linkClicks.startRecordingClicks(input: first) { [] }
        runtime.swipeNavigation.start(input: first)
        runtime.attachInput(second)
        #expect(runtime.input === second)
        #expect(first.subscriberCount(.button, stage: .intercept) == 0)
        #expect(first.subscriberCount(.scroll, stage: .intercept) == 0)
        #expect(second.subscriberCount(.button, stage: .intercept) == 1)
        #expect(second.subscriberCount(.key, stage: .intercept) == 1)
        #expect(second.subscriberCount(.scroll, stage: .intercept) == 1)
        runtime.attachInput(second)
        #expect(second.subscriberCount(.button, stage: .intercept) == 1, "the same tap again adds nothing")
    }

    /// Each engine gives the process-wide runtime its tap; the newest one is heard.
    @Test func eachEngineGivesTheRuntimeItsTap() {
        let first = InputEventTap()
        let second = InputEventTap()
        _ = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: first)
        #expect(CEFRuntime.shared.input === first)
        _ = CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks(), input: second)
        #expect(CEFRuntime.shared.input === second)
    }
}
