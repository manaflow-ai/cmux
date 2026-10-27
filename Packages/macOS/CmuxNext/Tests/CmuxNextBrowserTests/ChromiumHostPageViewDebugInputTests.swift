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

    /// A pane keeps parked content hidden in its tree (another profile's page host, a retired browser view):
    /// a hidden page view placed before the shown one is never the pane's page.
    @Test func aHiddenPageViewBeforeTheShownOneIsSkipped() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let parked = NSView(frame: root.bounds)
        parked.isHidden = true
        root.addSubview(parked)
        parked.addSubview(makePage(.view))
        let hiddenPage = makePage(.view)
        hiddenPage.isHidden = true
        root.addSubview(hiddenPage)
        #expect(ChromiumHostPageView.firstTakingInput(in: root) == nil, "only hidden page views: none is shown")

        let shown = makePage(.view)
        root.addSubview(shown)
        #expect(ChromiumHostPageView.firstTakingInput(in: root) === shown)
        #expect(ChromiumHostPageView.firstTakingInput(in: parked) == nil, "a search from inside hidden content finds nothing")
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A view of the shell window that takes every Command chord (a shortcut button, a shell control).
    final class ChordTaker: NSView {
        var taken = 0
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            taken += 1
            return true
        }
    }

    func chord(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 1,
                                      windowNumber: window.windowNumber, context: nil, characters: "k",
                                      charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))
    }

    /// `debug.key` says a chord was the page's only when the page view took it: the page view counts the
    /// chords it takes, and a chord another view of the window takes leaves the count alone.
    @Test func thePageViewCountsOnlyTheChordsItTakes() throws {
        let page = makePage(.view)
        let window = window(holding: page)
        page.sink = { _ in nil }
        #expect(window.makeFirstResponder(page))

        // The host does not report unhandled keys: the page view leaves chords to the window's other views.
        let shell = ChordTaker(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(shell)
        #expect(window.performKeyEquivalent(with: try chord(window)))
        #expect(shell.taken > 0)
        #expect(page.keyEquivalentsTaken == 0, "another view took the chord")

        shell.removeFromSuperview()
        page.hostReportsUnhandledKeys = true
        #expect(page.performKeyEquivalent(with: try chord(window)))
        #expect(page.keyEquivalentsTaken == 1)
        #expect(page.wireReport.keyEquivalentsTaken == 1)
    }

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
