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
                             makeLayerHost: { _ in CALayer() }, windowEventCenter: NotificationCenter())
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    @Test func appKitButtonsMapToWebButtons() {
        // AppKit: 0 left, 1 right, 2 middle, 3 back, 4 forward. The wire (Chrome's
        // WebPointerProperties::Button, as CEF clicks it): 0 left, 1 middle, 2 right.
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 0) == 0)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 1) == 2)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 2) == 1)
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 3) == nil, "back waits for the host to send kBack (054b)")
        #expect(ChromiumHostPageView.wireButton(buttonNumber: 4) == nil, "forward waits for the host to send kForward (054b)")
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

    /// The back and forward buttons put no press or release on the wire until the host can send
    /// them as kBack and kForward (054b): the host clicks with CEF's left, middle and right only, and
    /// 042's dispatch once took any other button for a left click at the pointer.
    @Test func backAndForwardClickNothingAndTheMiddleButtonIsMiddle() throws {
        let page = makePage()
        var frames: [ChromiumHostFrame] = []
        page.sink = { frames.append($0); return nil }
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 3))
        page.otherMouseUp(with: try otherMouse(.otherMouseUp, number: 3))
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 4))
        page.otherMouseUp(with: try otherMouse(.otherMouseUp, number: 4))
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 7))
        #expect(frames.isEmpty, "a back, forward or sixth button press reached the wire")
        page.otherMouseDragged(with: try otherMouse(.otherMouseDragged, number: 3))
        page.otherMouseDown(with: try otherMouse(.otherMouseDown, number: 2))
        page.otherMouseDragged(with: try otherMouse(.otherMouseDragged, number: 2))
        page.otherMouseUp(with: try otherMouse(.otherMouseUp, number: 2))
        #expect(frames.map(\.kind) == [.mouse, .mouse, .mouse, .mouse])
        // v2 phase (1 down, 2 up, 0 move), v3 the wire button: a drag under the back button is a move.
        #expect(frames.map { [$0.v[2], $0.v[3]] } == [[0, 0], [1, 1], [0, 1], [2, 1]])
        #expect(frames.allSatisfy { $0.v[2] == 0 || $0.v[3] == 1 }, "a press or release that is not the middle one")
        #expect(frames.map { $0.v[4] } == [0, 1, 0, 1], "a click count on presses and releases, none on a drag")
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
        #expect(page.pageTooltip == "Open the menu")
        page.pageTooltip = ""
        #expect(page.pageTooltip == nil, "an empty tooltip hides it")
        page.pageTooltip = "Again"
        page.pageTooltip = nil
        #expect(page.pageTooltip == nil)
    }

    #if DEBUG || CMUX_BENCH_HOOKS
    /// A force click's Look Up: the page's answer decodes to the word, its box and font in page points;
    /// no word, a malformed answer, an exception or a paragraph shows nothing.
    @Test func theLookUpAnswerDecodesOnlyAWord() {
        let answer = #"{"word":"parity","x":12.5,"baseline":40,"size":16,"family":"\"Helvetica Neue\", Arial, sans-serif"}"#
        let word = ChromiumHostLookUpWord(result: CEFEvaluationResult(status: 1, text: answer))
        #expect(word == ChromiumHostLookUpWord(word: "parity", x: 12.5, baseline: 40, size: 16, family: "\"Helvetica Neue\", Arial, sans-serif"))
        #expect(ChromiumHostLookUpWord(result: CEFEvaluationResult(status: 1, text: "null")) == nil, "no word at the point")
        #expect(ChromiumHostLookUpWord(result: CEFEvaluationResult(status: 1, text: "")) == nil)
        #expect(ChromiumHostLookUpWord(result: CEFEvaluationResult(status: 0, text: answer)) == nil, "an exception")
        #expect(ChromiumHostLookUpWord(result: CEFEvaluationResult(status: 1, text: "{\"word\":1}")) == nil, "malformed")
        let long = String(repeating: "a", count: ChromiumHostLookUpWord.maxLength + 1)
        #expect(ChromiumHostLookUpWord(result: CEFEvaluationResult(status: 1, text: answer.replacingOccurrences(of: "parity", with: long))) == nil)
        let font = word?.attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == 16, "the page's size")
    }

    @Test func theLookUpScriptTakesOnlyNumbers() {
        let script = ChromiumHostLookUpWord.script(at: CGPoint(x: CGFloat.nan, y: 30), scale: 0)
        #expect(script.contains("x = 0.0 / z, y = 30.0 / z"), "a point that is not finite is 0")
        #expect(script.contains("devicePixelRatio / 1.0"), "a scale that is not positive is 1")
    }

    /// With no word source (in process, or before the pane wires it) Look Up stays AppKit's; with one,
    /// the event's page point goes to it and nothing waits for the answer.
    @Test func lookUpAsksThePaneForTheWordAtThePoint() throws {
        let page = makePage()
        var asked: [CGPoint] = []
        var answer: ((ChromiumHostLookUpWord?) -> Void)?
        page.wordLookUp = { point, _, answered in
            asked.append(point)
            answer = answered
        }
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 40, y: 60),
                                      mouseButton: .left))
        page.quickLook(with: try #require(NSEvent(cgEvent: cg)))
        #expect(asked.count == 1, "the force click asked nothing")
        answer?(nil)
    }

    @Test func aRuntimeWithNoShimAnswersTheLookUpWithNothing() {
        let runtime = CEFRuntime(storage: CEFProfileStorage(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        var answered: [CEFEvaluationResult?] = []
        runtime.evaluateLatest(7, world: "cmux", script: "1") { answered.append($0) }
        #expect(answered == [nil], "no shim, no evaluate: the caller must hear so at once")
    }
    #endif

    @Test func aTooltipEventDecodes() {
        #expect(CEFShimEvent(kind: 57, browser: 7, request: 0, a: 0, b: 0, s1: "Save", s2: "") == .pageView(browser: 7, .tooltip("Save")))
        #expect(CEFShimEvent(kind: 57, browser: 7, request: 0, a: 0, b: 0, s1: "", s2: "") == .pageView(browser: 7, .tooltip("")))
    }
}
