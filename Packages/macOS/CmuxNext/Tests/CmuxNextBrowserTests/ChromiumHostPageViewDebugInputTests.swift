import AppKit
@testable import CmuxNextBrowser
import Testing

/// Task 224 of plans/cmux-next/chrome-parity/p01-process.md: `debug.key` and `debug.mouse` drive a hosted
/// page view through its cmux window's `sendEvent`, as AppKit hands a real event on (the page has no window
/// of its own), and `debug.cef` reports the remote shim's wire counters.
@MainActor
@Suite struct ChromiumHostPageViewDebugInputTests {
    func makePage(_ target: ChromiumHostPageView.InputTarget, frame: NSRect = NSRect(x: 0, y: 0, width: 400, height: 300))
        -> ChromiumHostPageView {
        ChromiumHostPageView(frame: frame, inputTarget: target, makeLayerHost: { _ in CALayer() }, pageUpdateCenter: NotificationCenter())
    }

    @Test func theFirstPageThatTakesInputIsFoundUnderContainersAndAPageWindowTargetIsNot() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let container = NSView(frame: root.bounds)
        root.addSubview(container)
        let inProcess = makePage(.pageWindow)
        container.addSubview(inProcess)
        #expect(ChromiumHostPageView.firstTakingInput(in: root) == nil, "an in-process page view's input goes to its page window")

        let hosted = makePage(.view)
        container.addSubview(hosted)
        #expect(ChromiumHostPageView.firstTakingInput(in: root) === hosted)
        #expect(hosted.takesPageInput)
        #expect(!inProcess.takesPageInput)
        #expect(hosted.shownContextID == 0, "no context shown yet")
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    func window(holding page: ChromiumHostPageView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(page)
        return window
    }

    /// A key-down the cmux window's `sendEvent` gets reaches the page view, its first responder, as one key frame.
    @Test func aKeyThroughTheWindowReachesTheFirstResponderPageView() throws {
        let page = makePage(.view)
        let window = window(holding: page)
        var frames: [ChromiumHostFrame] = []
        page.sink = { frames.append($0); return nil }
        #expect(window.makeFirstResponder(page))
        frames.removeAll()  // the focus frame

        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                                                windowNumber: window.windowNumber, context: nil, characters: "a",
                                                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        window.sendEvent(key)

        #expect(frames.contains { $0.kind == .key && $0.v[0] == 0 && $0.v[1] == 0 }, "the key-down never reached the page's wire")
        #expect(page.wireReport.hasInputRoute)
    }

    /// A left click the cmux window's `sendEvent` gets at a point of the page view goes to the view under it,
    /// which takes the keyboard and sends a press and a release.
    @Test func aClickThroughTheWindowReachesThePageViewUnderThePoint() throws {
        let page = makePage(.view)
        let window = window(holding: page)
        var frames: [ChromiumHostFrame] = []
        page.sink = { frames.append($0); return nil }
        func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 100, y: 200), modifierFlags: [], timestamp: 1,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                            pressure: type == .leftMouseDown ? 1 : 0))
        }

        window.sendEvent(try mouse(.leftMouseDown))
        window.sendEvent(try mouse(.leftMouseUp))

        let clicks = frames.filter { $0.kind == .mouse }
        // v0,v1 the page point (top-left), v2 the phase (1 down, 2 up).
        #expect(clicks.map { [$0.v[0], $0.v[1], $0.v[2]] } == [[100, 100, 1], [100, 100, 2]])
        #expect(window.firstResponder === page, "a press makes the page view first responder")
    }

    @Test func theWireReportCountsHeldChordsAndTheLastWheel() throws {
        let page = makePage(.view)
        page.sink = { _ in ChromiumHostInputReceipt(browser: 1, seq: 7) }
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -3, wheel2: 0, wheel3: 0))
        page.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(page.wireReport.lastWheelSeq == 7)
        #expect(page.wireReport.heldKeyDowns == 0)
        #expect(!page.wireReport.passwordInput)
    }
    #endif

    @Test func theRemoteShimCountersReadInTheCStructsOrder() throws {
        let stats = try #require(ChromiumHostRemoteWireStats(fields: [1, 2, 3, 4, 5, 6, 7]))
        #expect(stats.quotaExcess == 1)
        #expect(stats.coalesced == 2)
        #expect(stats.pendingMessages == 3)
        #expect(stats.readsUnattached == 4)
        #expect(stats.unsendable == 5)
        #expect(stats.repliesUnhandled == 6)
        #expect(stats.unsupported == 7)
        #expect(stats.report["quota_excess"] == 1)
        #expect(stats.report["unsupported"] == 7)
        #expect(ChromiumHostRemoteWireStats(fields: [1, 2, 3]) == nil, "another struct layout")
    }
}
