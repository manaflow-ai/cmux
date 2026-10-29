import CoreGraphics
import Foundation
import Testing
@testable import CmuxMobileTerminal

/// SPEC M1: the key bar's ctrl is a real modifier, from the composer too.
@Suite struct TerminalCtrlModifierTests {
    @Test func armedCtrlSendsTheControlKeyAndDisarms() {
        var router = TerminalInputRouter()
        router.tapSticky(.control, at: 10)
        let actions = router.composerKey("c")
        guard case .key(let press)? = actions?.first else {
            Issue.record("ctrl+c from the composer did not become a key event")
            return
        }
        #expect(press.mods.contains(.control))
        #expect(press.text == "c")
        #expect(actions?.count == 2)
        // Armed: one key, then off; the next letter stays in the composer.
        #expect(router.sticky.control == .off)
        #expect(router.composerKey("e") == nil)
    }

    @Test func nothingArmedLeavesTextToTheComposer() {
        var router = TerminalInputRouter()
        #expect(router.composerKey("h") == nil)
    }

    @Test func returnAndPastesStayInTheComposer() {
        var router = TerminalInputRouter()
        router.tapSticky(.control, at: 10)
        #expect(router.composerKey("\n") == nil)
        #expect(router.composerKey("hello") == nil)
        #expect(router.sticky.control != .off)
    }

    @Test func doubleTapLocksUntilTappedAgain() {
        var router = TerminalInputRouter()
        router.tapSticky(.control, at: 10)
        router.tapSticky(.control, at: 10.2)
        #expect(router.sticky.control == .locked)
        _ = router.composerKey("c")
        _ = router.composerKey("d")
        #expect(router.sticky.control == .locked)
        router.tapSticky(.control, at: 12)
        #expect(router.sticky.control == .off)
    }

    @Test func altSendsAnEscapePrefixedKey() {
        var router = TerminalInputRouter()
        router.tapSticky(.alternate, at: 1)
        guard case .key(let press)? = router.composerKey("b")?.first else {
            Issue.record("alt+b did not become a key event")
            return
        }
        #expect(press.mods.contains(.alternate))
        #expect(router.sticky.alternate == .off)
    }
}

/// Classic cmux iOS's ⌘ and ⇧ on the key row.
@Suite struct TerminalCommandShiftModifierTests {
    @Test func commandLeftAndRightAreLineStartAndEnd() {
        var router = TerminalInputRouter()
        router.tapSticky(.command, at: 1)
        guard case .key(let start)? = router.key(usage: TerminalHIDUsage.left).first else {
            Issue.record("⌘← sent no key")
            return
        }
        // ^A: the a key with Control, never a Command (super) key.
        #expect(start.mods == .control)
        #expect(start.text == "a")
        #expect(router.sticky.command == .off)
        router.tapSticky(.command, at: 2)
        guard case .key(let end)? = router.key(usage: TerminalHIDUsage.right).first else {
            Issue.record("⌘→ sent no key")
            return
        }
        #expect(end.mods == .control)
        #expect(end.text == "e")
    }

    @Test func commandOnOtherKeysIsDropped() {
        var router = TerminalInputRouter()
        router.tapSticky(.command, at: 1)
        guard case .key(let up)? = router.key(usage: TerminalHIDUsage.up).first else {
            Issue.record("⌘↑ sent no key")
            return
        }
        #expect(up.mods.isEmpty)
        #expect(router.insertText("x") == [.text("x")])
    }

    @Test func shiftTabIsBackTabAndShiftUppercasesOneLetter() {
        var router = TerminalInputRouter()
        router.tapSticky(.shift, at: 1)
        guard case .key(let tab)? = router.key(usage: TerminalHIDUsage.tab).first else {
            Issue.record("⇧Tab sent no key")
            return
        }
        #expect(tab.mods == .shift)
        router.tapSticky(.shift, at: 2)
        #expect(router.insertText("q") == [.text("Q")])
        // Armed: one key, then off.
        #expect(router.insertText("q") == [.text("q")])
    }

    /// Review finding: Send's Return after its paste is a bare Enter. An armed
    /// ⇧ (or a locked ⌃) left from the key row made it Shift-Enter, which
    /// Claude Code and Codex read as a new line, so the prompt never ran.
    @Test func theComposersReturnIgnoresStickyModifiers() {
        var router = TerminalInputRouter()
        router.tapSticky(.shift, at: 1)
        router.tapSticky(.control, at: 2)
        router.tapSticky(.control, at: 2.1)
        guard case .key(let enter)? = router.plainKey(usage: TerminalHIDUsage.enter).first else {
            Issue.record("no Return")
            return
        }
        #expect(enter.mods.isEmpty)
        // And the modifiers are still there for the next key.
        #expect(router.sticky.shift != .off)
        #expect(router.sticky.control == .locked)
    }

    @Test func everyModifierLocksOnADoubleTap() {
        for modifier in TerminalStickyModifiers.Modifier.allCases {
            var sticky = TerminalStickyModifiers()
            sticky.tap(modifier, at: 5)
            sticky.tap(modifier, at: 5.3)
            #expect(sticky.state(modifier) == .locked)
            #expect(sticky.consume().contains(modifier.keyMod))
            #expect(sticky.state(modifier) == .locked)
            sticky.reset()
            #expect(sticky.state(modifier) == .off)
        }
    }
}

/// The key row: classic cmux iOS's keys in its default order.
@Suite struct TerminalKeyRowTests {
    @Test func theRowIsClassicsOrder() {
        #expect(Array(KeyBarKey.row.prefix(10)) == [
            .control, .alternate, .command, .shift, .paste, .tab, .escape, .returnKey, .chord("c"), .chord("d"),
        ])
        #expect(Array(KeyBarKey.row.suffix(3)) == [.zoomOut, .zoomIn, .hideChrome])
        #expect(Set(KeyBarKey.row).count == KeyBarKey.row.count)
        // The compose key is pinned, never in the scroller.
        #expect(!KeyBarKey.row.contains(.composer))
        #expect(KeyBarKey.chord("l").label == "Clear")
        #expect(KeyBarKey.control.label == "⌃")
    }

    @Test func launchersTypeClassicsCommands() {
        #expect(KeyBarLauncher.claude.command == "claude --dangerously-skip-permissions")
        #expect(KeyBarLauncher.claude.pressesReturn)
        #expect(KeyBarLauncher.codex.pressesReturn)
        // Ollama waits for the model name.
        #expect(KeyBarLauncher.ollama.command == "ollama run ")
        #expect(!KeyBarLauncher.ollama.pressesReturn)
    }

    @Test func keysFadeAtThePinnedKeysOnlyOnceScrolled() {
        let fade = KeyRowFade()
        #expect(fade.leadingEdgeAlpha(scrolled: 0) == 1)
        #expect(fade.leadingEdgeAlpha(scrolled: 12) == 0.5)
        #expect(fade.leadingEdgeAlpha(scrolled: 200) == 0)
        // Rubber-band past the start: still no fade.
        #expect(fade.leadingEdgeAlpha(scrolled: -30) == 1)
    }

    @Test func zoomStepsOnePointWithinTheSettingsRange() {
        let zoom = TerminalFontZoom(sizes: 9...24)
        #expect(zoom.step(12, larger: true) == 13)
        #expect(zoom.step(12, larger: false) == 11)
        #expect(zoom.step(24, larger: true) == 24)
        #expect(zoom.step(9, larger: false) == 9)
    }
}

/// Classic cmux iOS's compose key (`ComposerDockState`): a tap never closes
/// a composer the person is trying to reach.
@Suite struct ComposerDockStateTests {
    @Test func closedOpens() {
        let dock = ComposerDockState(chromeHidden: false, composerPresented: false, fieldFocused: false)
        #expect(dock.intentForComposeKeyTap() == .openComposer)
    }

    @Test func shownButUnfocusedOrHiddenRevealsAndFocuses() {
        #expect(ComposerDockState(chromeHidden: false, composerPresented: true, fieldFocused: false)
            .intentForComposeKeyTap() == .revealAndFocusComposer)
        #expect(ComposerDockState(chromeHidden: true, composerPresented: true, fieldFocused: true)
            .intentForComposeKeyTap() == .revealAndFocusComposer)
    }

    @Test func onlyShownAndFocusedCloses() {
        let dock = ComposerDockState(chromeHidden: false, composerPresented: true, fieldFocused: true)
        #expect(dock.intentForComposeKeyTap() == .closeComposer)
    }
}

/// The dock: key row always, composer open by default, Hide Toolbar folds both.
@Suite struct TerminalDockVisibilityTests {
    @Test func theKeyRowShowsWithTheKeyboardUpOrDown() {
        var dock = TerminalDockVisibility()
        #expect(dock.showsKeyRow && dock.showsComposer)
        dock.keyboardWillShow(visibleHeight: 336)
        #expect(dock.softKeyboard == .shown)
        #expect(dock.showsKeyRow)
        dock.keyboardWillHide()
        dock.keyboardDidHide()
        #expect(dock.showsKeyRow)
        // A hardware keyboard's bar is no soft keyboard.
        dock.keyboardWillShow(visibleHeight: 44)
        #expect(dock.softKeyboard == .none)
    }

    @Test func hideToolbarFoldsBothAndKeepsTheComposerOpen() {
        var dock = TerminalDockVisibility()
        dock.chromeHidden = true
        #expect(!dock.showsKeyRow && !dock.showsComposer)
        #expect(dock.composerPresented)
        dock.chromeHidden = false
        #expect(dock.showsComposer)
    }

    @Test func restingHeightFollowsWhatShows() {
        let metrics = TerminalDockMetrics()
        let line: CGFloat = 20.29
        // SF body: 20.29 + 2 x (3 + 6) = 38.3 -> the 40 pt circles win.
        #expect(metrics.restingComposerHeight(lineHeight: line) == 40)
        #expect(metrics.restingStackHeight(lineHeight: line, visibility: TerminalDockVisibility()) == CGFloat(28 + 8 + 40))
        #expect(metrics.restingStackHeight(lineHeight: line, visibility: TerminalDockVisibility(composerPresented: false)) == 28)
        #expect(metrics.restingStackHeight(lineHeight: line, visibility: TerminalDockVisibility(chromeHidden: true)) == 0)
        // Larger text: taller, but still fixed for that size.
        #expect(metrics.restingComposerHeight(lineHeight: 40) == 58)
    }
}

@Suite struct JoystickAndComposerGeometryTests {
    @Test func theThumbFollowsTheFingerPastTheCircleUpToACap() {
        let geometry = JoystickGeometry()
        #expect(JoystickGeometry.travel == 48)
        #expect(JoystickGeometry.circle == 28)
        // Inside the cap the thumb is under... beside the finger: no scaling.
        #expect(geometry.thumbOffset(for: CGSize(width: 30, height: 0)) == CGSize(width: 30, height: 0))
        // Beyond it, capped along the same direction.
        let capped = geometry.thumbOffset(for: CGSize(width: 60, height: 80))
        #expect(abs(hypot(capped.width, capped.height) - 48) < 0.001)
        #expect(abs(capped.width / capped.height - 0.75) < 0.001)
    }
}

/// Codex QA F5: the joystick repeats like a held key.
@Suite struct JoystickRepeatTests {
    let rule = JoystickRepeat()

    @Test func aFlickSendsExactlyOneArrow() {
        #expect(rule.arrows(holding: 0.15, at: 40) == 1)
        #expect(rule.arrows(holding: 0.39, at: 48) == 1)
        #expect(rule.arrows(holding: 0.3, at: 4) == 0)
    }

    @Test func aHoldRepeatsAfter400msAtAboutTenASecond() {
        #expect(rule.rate(distance: 20) == 10)
        // 1.2 s at 30 pt: 1 + 0.8 s x 11.5 = 10 arrows, not ~40.
        #expect(rule.arrows(holding: 1.2, at: 30) <= 10)
        #expect(rule.interval(distance: 20) == .milliseconds(100))
    }

    @Test func theRateRisesGentlyWithDistanceAndIsCapped() {
        #expect(rule.rate(distance: 36) > rule.rate(distance: 24))
        #expect(rule.rate(distance: 48) == JoystickRepeat.fastestRate)
        #expect(rule.rate(distance: 200) == JoystickRepeat.fastestRate)
        #expect(JoystickRepeat.fastestRate <= 20)
    }
}
