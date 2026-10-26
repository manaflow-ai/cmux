import AppKit
@testable import CmuxNextBrowser
import Testing

/// Task 054 of plans/cmux-next/chrome-parity/p01-process.md: the host page view sends the mouse
/// input Chrome's page view sends past clicks, moves and the wheel (the back and forward buttons,
/// pinch, smart zoom, Force Touch pressure), and shows the page's tooltip.
@MainActor
@Suite struct ChromiumHostPageViewGestureTests {
    func makePage() -> ChromiumHostPageView {
        ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), inputTarget: .view,
                             makeLayerHost: { _ in CALayer() }, pageUpdateCenter: NotificationCenter())
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test func appKitButtonsMapToWebButtons() {
        // AppKit: 0 left, 1 right, 2 middle, 3 back, 4 forward. The wire (Chrome's
        // WebPointerProperties::Button): 0 left, 1 middle, 2 right, 3 back, 4 forward.
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 0) == 0)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 1) == 2)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 2) == 1)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 3) == 3)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 4) == 4)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 5) == nil, "no web button past the fifth")
    }

    @Test func pressedButtonsKeepTheBackAndForwardBits() {
        #expect(ChromiumHostPageView.pressedButtons(0b1_1000) == 24, "back 8 and forward 16, as MouseEvent.buttons")
        #expect(ChromiumHostPageView.pressedButtons(0xff) == 0x1f, "buttons past the fifth have no bit")
    }

    /// An `otherMouse` event of AppKit button `number` (NSEvent.mouseEvent leaves buttonNumber 0 on
    /// these, so it is made from a CGEvent, as debug.mouse does).
    func otherMouse(_ type: CGEventType, number: Int64) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 40, y: 60),
                                      mouseButton: .center))
        cg.setIntegerValueField(.mouseEventButtonNumber, value: number)
        cg.setIntegerValueField(.mouseEventClickState, value: 1)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func backAndForwardReachThePageAsTheirOwnButtons() throws {
        let page = makePage()
        var frames: [ChromiumHostFrame] = []
        page.sink = { frames.append($0); return nil }
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 3))
        page.otherMouseUp(with: try otherMouse(.otherMouseUp, number: 3))
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 4))
        page.otherMouseDragged(with: try otherMouse(.otherMouseDragged, number: 2))
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 7))
        #expect(frames.map(\.kind) == [.mouse, .mouse, .mouse, .mouse], "a sixth or later button sends nothing")
        // v2 phase (1 down, 2 up, 0 move), v3 the wire button.
        #expect(frames.map { [$0.v[2], $0.v[3]] } == [[1, 3], [2, 3], [1, 4], [0, 1]])
        #expect(frames.map { $0.v[4] } == [1, 1, 1, 0], "a click count on presses and releases, none on a drag")
    }

    @Test func aPinchIsBeginUpdatesEnd() {
        let pinch = ChromiumHostPageView.pinch
        #expect(pinch(.began, 0.25) == [.init(type: .pinchBegin), .init(type: .pinchUpdate, value: 1_250_000)])
        #expect(pinch(.changed, -0.1) == [.init(type: .pinchUpdate, value: 900_000)])
        #expect(pinch(.ended, 0) == [.init(type: .pinchEnd)])
        #expect(pinch(.cancelled, 0.3) == [.init(type: .pinchEnd)], "a cancelled pinch ends without its step")
        #expect(pinch([], 0.5) == [.init(type: .pinchBegin), .init(type: .pinchUpdate, value: 1_500_000), .init(type: .pinchEnd)],
                "a magnify with no phase is a whole pinch")
    }

    @Test func pressureIsMillionthsWithItsStage() {
        #expect(ChromiumHostPageView.pressure(0.25, stage: 1) == .init(type: .pressure, value: 250_000, stage: 1))
        #expect(ChromiumHostPageView.pressure(1.5, stage: 3) == .init(type: .pressure, value: 1_000_000, stage: 2))
        #expect(ChromiumHostPageView.pressure(-1, stage: -1) == .init(type: .pressure, value: 0, stage: 0))
        #expect(ChromiumHostPageView.pressure(.nan, stage: 2) == .init(type: .pressure, value: 0, stage: 2))
        #expect(ChromiumHostPageView.millionths(1e30) == Int32.max, "held to the wire's range, no trap")
        #expect(ChromiumHostPageView.millionths(-.infinity) == 0)
    }

    @Test func gestureFramesAreOrderedInputOfTheirOwnKind() {
        #expect(ChromiumHostFrame.Kind.gesture.rawValue == 13, "kGesture in chromium_host_wire.h")
        #expect(ChromiumHostFrame.Kind.gesture.traceInput == nil)
        #expect(!ChromiumHostInputOutbox.isCoalescible(ChromiumHostFrame(.gesture, v: [0, 0, 1, 1_100_000])),
                "a pinch step is never folded into another")
    }
    #endif

    @Test func theTooltipShowsOnThePageView() {
        let page = makePage()
        page.pageTooltip = "Open the menu"
        #expect(page.toolTip == "Open the menu")
        page.pageTooltip = ""
        #expect(page.toolTip == nil, "an empty tooltip hides it")
        page.pageTooltip = "Again"
        page.pageTooltip = nil
        #expect(page.toolTip == nil)
    }

    @Test func aTooltipEventDecodes() {
        #expect(CEFShimEvent(kind: 57, browser: 7, request: 0, a: 0, b: 0, s1: "Save", s2: "") == .tooltip(browser: 7, text: "Save"))
        #expect(CEFShimEvent(kind: 57, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .tooltip(browser: 7, text: ""))
    }
}
