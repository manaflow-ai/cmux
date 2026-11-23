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

/// The key row: classic cmux iOS's keys, the launchers last (option B of cmux#50880).
@Suite struct TerminalKeyRowTests {
    @Test func theRowHasOnlyKeysByTheArrowsAndTheLaunchersLast() {
        // Leo, 2026-11-22, on Claude right after →: "surely we can think of more ergonomic ways to do things...?"
        #expect(Array(KeyBarKey.row.prefix(14)) == [
            .control, .alternate, .command, .shift, .paste, .tab, .escape, .returnKey, .chord("c"), .chord("d"),
            .up, .down, .left, .right,
        ])
        #expect(KeyBarKey.row[14] == .chord("l"), "a key, not a launcher, right after →")
        #expect(Array(KeyBarKey.row.suffix(5)) == [
            .zoomOut, .zoomIn, .launcher(.claude), .launcher(.codex), .launcher(.ollama),
        ])
        #expect(KeyBarLayout.standard == .agentsLast)
        #expect(KeyBarLayout.standard.launcherSeparatorKey == KeyBarKey.launcher(.claude), "the hairline before the launchers")
        #expect(Set(KeyBarKey.row).count == KeyBarKey.row.count)
        // The compose key is pinned, never in the scroller.
        #expect(!KeyBarKey.row.contains(.composer))
        #expect(KeyBarKey.chord("l").label == "Clear")
        #expect(KeyBarKey.control.label == "⌃")
    }

    @Test func everyLayoutHasEveryKeyOnceAndTheArrowsBeforeTheAgents() {
        let reference = Set(KeyBarLayout.standard.scroller)
        for layout in KeyBarLayout.allCases {
            let row = layout.scroller
            #expect(Set(row) == reference, "\(layout)")
            #expect(row.count == reference.count, "\(layout)")
            let lastArrow = row.lastIndex { KeyBarKey.arrows.contains($0) }
            let firstAgent = row.firstIndex(where: \.isLauncher)
            #expect(lastArrow! < firstAgent!, "\(layout)")
            #expect(layout.launcherSeparatorKey == row[firstAgent!], "\(layout)")
        }
    }

    @Test func launchersTypeClassicsCommands() {
        #expect(KeyBarLauncher.claude.command == "claude --dangerously-skip-permissions")
        // Ollama waits for the model name.
        #expect(KeyBarLauncher.ollama.command == "ollama run ")
    }

    /// A tap only types the command: one stray thumb used to run
    /// `claude --dangerously-skip-permissions`. Run Now (long-press) adds Return.
    @Test func aLauncherTapNeverPressesReturn() {
        let router = TerminalInputRouter()
        let enter = TerminalHIDUsage.ghosttyKeyCode(TerminalHIDUsage.enter)
        for launcher in [KeyBarLauncher.claude, .codex, .ollama] {
            let tap = launcher.input(.insert, router: router)
            #expect(tap == [.text(launcher.command)], "\(launcher)")
            let keys = tap.compactMap { action -> TerminalKeyEvent? in
                if case .key(let event) = action { event } else { nil }
            }
            #expect(keys.isEmpty, "\(launcher): a tap sends no key, so no Return")
            let run = launcher.input(.run, router: router)
            #expect(run.first == .text(launcher.command))
            let runKeys = run.compactMap { action -> TerminalKeyEvent? in
                if case .key(let event) = action { event } else { nil }
            }
            #expect(runKeys.count == 2 && runKeys.allSatisfy { $0.keyCode == enter }, "\(launcher): Run Now presses Return")
        }
    }

    /// Apple HIG, Accessibility: "a hit region of at least 44x44 pt"
    /// (https://developer.apple.com/design/human-interface-guidelines/accessibility).
    @Test func everyKeysHitAreaIsAtLeast44Points() {
        let hit = KeyRowHitTarget()
        let row = TerminalDockMetrics.keyRowHeight
        let caps: [(String, CGSize)] = [
            ("glyph key", CGSize(width: TerminalDockMetrics.minKeyWidth, height: row)),
            ("word key", CGSize(width: 60, height: row)),
            ("joystick", CGSize(width: JoystickGeometry.circle, height: JoystickGeometry.circle)),
            ("keyboard key", CGSize(width: row + 12, height: row)),
        ]
        for (name, cap) in caps {
            let size = hit.hitSize(cap: cap)
            #expect(size.width >= 44 && size.height >= 44, "\(name): \(size)")
        }
        // A glyph key's hit area is exactly its share: 44 pt, caps 6 pt apart.
        #expect(hit.hitSize(cap: caps[0].1) == CGSize(width: 44, height: 44))
        #expect(KeyRowHitTarget.rowHitHeight >= 44, "the row's host view is the hit areas' height")
        #expect(KeyRowHitTarget.verticalSlop == 8)
        // The caps keep their 28 pt row: the PTY's rows are sized by it.
        #expect(TerminalDockMetrics.keyRowHeight == 28)
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
    @Test func theThumbsCenterReachesTheCirclesEdgeAndNoFarther() {
        let geometry = JoystickGeometry()
        #expect(JoystickGeometry.circle == 28)
        // The dot's center stops on the circle's edge (14 pt), not 48 pt out.
        #expect(JoystickGeometry.travel == 14)
        #expect(geometry.thumbOffset(for: CGSize(width: 4, height: -3)) == CGSize(width: 4, height: -3))
        // The screenshot's case: a long drag up moves the dot 14 pt.
        // (Scaling rounds: 200 x 14 / 200 is 14.000000000000002.)
        let up = geometry.thumbOffset(for: CGSize(width: 0, height: -120))
        #expect(abs(up.width) < 0.001 && abs(up.height + 14) < 0.001)
        let right = geometry.thumbOffset(for: CGSize(width: 200, height: 0))
        #expect(abs(right.width - 14) < 0.001 && abs(right.height) < 0.001)
        // Diagonally it keeps the finger's direction, on the same edge.
        let diagonal = geometry.thumbOffset(for: CGSize(width: 60, height: 80))
        #expect(abs(hypot(diagonal.width, diagonal.height) - 14) < 0.001)
        #expect(abs(diagonal.width / diagonal.height - 0.75) < 0.001)
        let corner = geometry.thumbOffset(for: CGSize(width: -500, height: 500))
        #expect(abs(hypot(corner.width, corner.height) - JoystickGeometry.circle / 2) < 0.001)
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
