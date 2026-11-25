import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// Leo, 2026-11-12: scrolling a Claude Code transcript on the phone clicked
/// the background-agent rows the thumb landed on. A tap over a full-screen
/// app clicks only when it is a deliberate tap, never as part of a scroll.
@Suite struct TerminalTUITapClickTests {
    @Test func aQuickStillTapClicks() {
        let tap = TerminalTUITapClick()
        #expect(tap.verdict(downAt: 10, upAt: 10.1, moved: 2) == .click)
    }

    @Test func aTouchThatLandsWhileTheAppScrollsDoesNothing() {
        var tap = TerminalTUITapClick()
        tap.scrolled(at: 10)
        // The next flick of a run of thumb flicks, too short to be a drag.
        #expect(tap.verdict(downAt: 10.2, upAt: 10.25, moved: 3) == .ignore)
        #expect(tap.verdict(downAt: 10 + TerminalTUITapClick.quietAfterScroll - 0.01, upAt: 10.6, moved: 0) == .ignore)
    }

    @Test func aTapClicksAgainOnceTheScrollSettles() {
        var tap = TerminalTUITapClick()
        tap.scrolled(at: 10)
        #expect(tap.verdict(downAt: 10 + TerminalTUITapClick.quietAfterScroll, upAt: 10.6, moved: 0) == .click)
    }

    @Test func aShortFlickOnlyFocuses() {
        let tap = TerminalTUITapClick()
        #expect(tap.verdict(downAt: 10, upAt: 10.1, moved: TerminalTUITapClick.maximumMovement + 1) == .focusOnly)
    }

    @Test func aRestingThumbOnlyFocuses() {
        let tap = TerminalTUITapClick()
        #expect(tap.verdict(downAt: 10, upAt: 10 + TerminalTUITapClick.maximumHold + 0.05, moved: 0) == .focusOnly)
    }
}
