import Foundation
import Testing
@testable import CmuxMobileTerminalKit

@Suite("TerminalInputModifierState armed/sticky reducer")
struct TerminalInputModifierStateTests {
    @Test("single tap arms the modifier")
    func singleTapArms() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        #expect(state.isArmed(.control))
        #expect(!state.isStickyOn(.control))
        #expect(state.armedModifier == .control)
    }

    @Test("tapping an armed modifier again after the interval disarms it")
    func secondTapAfterIntervalDisarms() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        state.tap(.control, now: 10) // well beyond the 0.4s window
        #expect(!state.isArmed(.control))
        #expect(state.armedModifier == nil)
    }

    @Test("double tap within interval promotes to sticky")
    func doubleTapStickies() {
        var state = TerminalInputModifierState()
        state.tap(.alternate, now: 0)
        state.tap(.alternate, now: 0.2)
        #expect(state.isArmed(.alternate))
        #expect(state.isStickyOn(.alternate))
    }

    @Test("tapping a sticky modifier turns everything off")
    func tapStickyOff() {
        var state = TerminalInputModifierState()
        state.tap(.command, now: 0)
        state.tap(.command, now: 0.1) // sticky
        #expect(state.isStickyOn(.command))
        state.tap(.command, now: 0.2)
        #expect(state.armedModifier == nil)
    }

    @Test("arming a different modifier disarms the previous one")
    func armingAnotherDisarmsPrevious() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        state.tap(.shift, now: 0.1)
        #expect(!state.isArmed(.control))
        #expect(state.isArmed(.shift))
        #expect(state.armedModifier == .shift)
    }

    @Test("arming a different modifier clears a sticky lock")
    func armingAnotherClearsSticky() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        state.tap(.control, now: 0.1) // sticky control
        #expect(state.isStickyOn(.control))
        state.tap(.alternate, now: 0.2)
        #expect(!state.isArmed(.control))
        #expect(state.isArmed(.alternate))
        #expect(!state.isStickyOn(.alternate))
    }

    @Test("consumeIfNotSticky disarms a one-shot but keeps a sticky lock")
    func consumeOneShotVsSticky() {
        var oneShot = TerminalInputModifierState()
        oneShot.tap(.control, now: 0)
        oneShot.consumeIfNotSticky(.control)
        #expect(oneShot.armedModifier == nil)

        var sticky = TerminalInputModifierState()
        sticky.tap(.control, now: 0)
        sticky.tap(.control, now: 0.1) // sticky
        sticky.consumeIfNotSticky(.control)
        #expect(sticky.isStickyOn(.control))
    }

    @Test("consumeIfNotSticky on a non-armed modifier is a no-op")
    func consumeNonArmedNoOp() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        state.consumeIfNotSticky(.shift)
        #expect(state.isArmed(.control))
    }

    @Test("disarmAll clears any state")
    func disarmAllClears() {
        var state = TerminalInputModifierState()
        state.tap(.command, now: 0)
        state.tap(.command, now: 0.1) // sticky
        state.disarmAll()
        #expect(state.armedModifier == nil)
        for modifier in TerminalInputModifier.allCases {
            #expect(!state.isArmed(modifier))
        }
    }

    @Test("clearDoubleTapWindow keeps armed state but blocks sticky promotion")
    func clearDoubleTapWindow() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        #expect(state.isArmed(.control))
        state.clearDoubleTapWindow()
        // Still armed...
        #expect(state.isArmed(.control))
        // ...but a tap that would have stickied (within interval) now just
        // toggles the armed modifier off instead, because the window is gone.
        state.tap(.control, now: 0.1)
        #expect(state.armedModifier == nil)
    }

    @Test("double-tap window is exclusive at the boundary")
    func doubleTapBoundaryExclusive() {
        var state = TerminalInputModifierState()
        state.tap(.control, now: 0)
        // Exactly at the interval is NOT within (strict <), so it re-toggles off.
        state.tap(.control, now: TerminalInputModifierState.stickyDoubleTapInterval)
        #expect(state.armedModifier == nil)
    }
}
