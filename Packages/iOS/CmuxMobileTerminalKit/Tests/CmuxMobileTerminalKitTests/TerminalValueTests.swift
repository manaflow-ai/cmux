import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalCursorBlinkState")
struct TerminalCursorBlinkStateTests {
    @Test("starts visible and does not toggle before the interval")
    func startsVisible() {
        var state = TerminalCursorBlinkState()
        state.start(now: 0)
        #expect(state.isVisible)
        let changed = state.advance(now: 0.49)
        #expect(changed == false)
        #expect(state.isVisible)
    }

    @Test("toggles once per elapsed half-period")
    func togglesPerInterval() {
        var state = TerminalCursorBlinkState()
        state.start(now: 0)
        let first = state.advance(now: 0.5)
        #expect(first)
        #expect(!state.isVisible)
        let second = state.advance(now: 1.0)
        #expect(second)
        #expect(state.isVisible)
    }

    @Test("a large gap of an even number of intervals leaves visibility unchanged")
    func evenIntervalsUnchanged() {
        var state = TerminalCursorBlinkState()
        state.start(now: 0)
        // 1.0s = 2 intervals -> even -> visibility unchanged, but still reports a change.
        let changed = state.advance(now: 1.0)
        #expect(changed)
        #expect(state.isVisible)
    }

    @Test("reset returns to visible")
    func resetVisible() {
        var state = TerminalCursorBlinkState()
        state.start(now: 0)
        _ = state.advance(now: 0.5) // now hidden
        #expect(!state.isVisible)
        state.reset(now: 0.5)
        #expect(state.isVisible)
    }
}

@Suite("TerminalTextInputPipeline")
struct TerminalTextInputPipelineTests {
    @Test("composing text never commits and keeps the buffer")
    func composing() {
        let result = TerminalTextInputPipeline.process(text: "あ", isComposing: true)
        #expect(result.committedText == nil)
        #expect(result.nextBufferText == "あ")
    }

    @Test("committed text empties the buffer")
    func commits() {
        let result = TerminalTextInputPipeline.process(text: "hello", isComposing: false)
        #expect(result.committedText == "hello")
        #expect(result.nextBufferText == "")
    }

    @Test("empty non-composing text commits nothing")
    func empty() {
        let result = TerminalTextInputPipeline.process(text: "", isComposing: false)
        #expect(result.committedText == nil)
        #expect(result.nextBufferText == "")
    }
}

@Suite("TerminalFontZoomDirection")
struct TerminalFontZoomDirectionTests {
    @Test("binding action strings match libghostty")
    func bindingAction() {
        #expect(TerminalFontZoomDirection.increase.bindingAction == "increase_font_size:1")
        #expect(TerminalFontZoomDirection.decrease.bindingAction == "decrease_font_size:1")
    }
}

@Suite("TerminalDECTCEMCursorScanner")
struct TerminalDECTCEMCursorScannerTests {
    @Test("detects hide sequence")
    func hide() {
        let data = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x6C]) // ESC [ ? 2 5 l
        #expect(TerminalDECTCEMCursorScanner.lastVisibility(in: data) == false)
    }

    @Test("detects show sequence")
    func show() {
        let data = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]) // ESC [ ? 2 5 h
        #expect(TerminalDECTCEMCursorScanner.lastVisibility(in: data) == true)
    }

    @Test("last occurrence wins when the chunk toggles")
    func lastWins() {
        var data = Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x6C]) // hide
        data.append(contentsOf: [0x41, 0x42]) // some text
        data.append(contentsOf: [0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]) // show
        #expect(TerminalDECTCEMCursorScanner.lastVisibility(in: data) == true)
    }

    @Test("no DECTCEM in chunk returns nil")
    func none() {
        #expect(TerminalDECTCEMCursorScanner.lastVisibility(in: Data("hello world".utf8)) == nil)
        #expect(TerminalDECTCEMCursorScanner.lastVisibility(in: Data([0x1B, 0x5B])) == nil)
    }
}
