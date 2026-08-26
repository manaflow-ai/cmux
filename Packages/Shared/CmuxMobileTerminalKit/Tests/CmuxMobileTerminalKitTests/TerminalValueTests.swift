import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalCursorRenderWakeState")
struct TerminalCursorRenderWakeStateTests {
    @Test("does not wake before the interval")
    func waitsForInterval() {
        var state = TerminalCursorRenderWakeState()
        state.start(now: 0)
        #expect(state.consumeWakeIfDue(now: 0.49) == false)
    }

    @Test("wakes at each interval")
    func wakesPerInterval() {
        var state = TerminalCursorRenderWakeState()
        state.start(now: 0)
        let first = state.consumeWakeIfDue(now: 0.5)
        let early = state.consumeWakeIfDue(now: 0.99)
        let second = state.consumeWakeIfDue(now: 1.0)
        #expect(first)
        #expect(early == false)
        #expect(second)
    }

    @Test("a large gap coalesces to one wake and preserves cadence")
    func coalescesLargeGap() {
        var state = TerminalCursorRenderWakeState()
        state.start(now: 0)
        let coalesced = state.consumeWakeIfDue(now: 2.1)
        let early = state.consumeWakeIfDue(now: 2.49)
        let next = state.consumeWakeIfDue(now: 2.5)
        #expect(coalesced)
        #expect(early == false)
        #expect(next)
    }

    @Test("reset restarts the wake deadline")
    func resetDeadline() {
        var state = TerminalCursorRenderWakeState()
        state.start(now: 0)
        state.reset(now: 0.4)
        let oldDeadline = state.consumeWakeIfDue(now: 0.5)
        let resetDeadline = state.consumeWakeIfDue(now: 0.9)
        #expect(oldDeadline == false)
        #expect(resetDeadline)
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
