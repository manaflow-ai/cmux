import Testing
import CmuxSettings
@testable import CmuxSettingsUI

@Suite("ShortcutDisplayString")
struct ShortcutDisplayStringTests {
    private func shortcut(
        key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> StoredShortcut {
        StoredShortcut(
            first: ShortcutStroke(
                key: key,
                command: command,
                shift: shift,
                option: option,
                control: control
            )
        )
    }

    @Test func numberedControlDigitRendersAsRange() {
        // Regression for https://github.com/manaflow-ai/cmux/issues/5189:
        // a rebound numbered shortcut must display the whole ⌃1…9 range, not ⌃1.
        let rebound = shortcut(key: "1", control: true)
        #expect(shortcutDisplayString(rebound, numbered: true) == "⌃1…9")
    }

    @Test func numberedCommandDigitRendersAsRange() {
        let defaultWorkspace = shortcut(key: "1", command: true)
        #expect(shortcutDisplayString(defaultWorkspace, numbered: true) == "⌘1…9")
    }

    @Test func numberedRangeIgnoresWhichDigitWasRecorded() {
        // The stored digit is normalized to a placeholder; any 1…9 digit
        // stands in for the whole family, so the display is digit-agnostic.
        let recordedWithFive = shortcut(key: "5", option: true)
        #expect(shortcutDisplayString(recordedWithFive, numbered: true) == "⌥1…9")
    }

    @Test func nonNumberedShortcutKeepsItsLiteralKey() {
        // Other actions that happen to bind a digit must keep the literal key.
        let cmdOne = shortcut(key: "1", command: true)
        #expect(shortcutDisplayString(cmdOne, numbered: false) == "⌘1")

        let closeTab = shortcut(key: "w", command: true)
        #expect(shortcutDisplayString(closeTab, numbered: false) == "⌘W")
    }

    @Test func numberedNonDigitKeyFallsBackToLiteral() {
        // A numbered action whose binding holds a non-1…9 key is not an active
        // range (the app-target parser rejects it), so the row must show the
        // literal key, never a false ⌃1…9 range. Verified by Codex review.
        #expect(shortcutDisplayString(shortcut(key: "a", control: true), numbered: true) == "⌃A")
    }

    @Test func numberedZeroAndOutOfRangeDigitsFallBackToLiteral() {
        #expect(shortcutDisplayString(shortcut(key: "0", command: true), numbered: true) == "⌘0")
    }

    @Test func unboundRendersAsNone() {
        #expect(shortcutDisplayString(.unbound, numbered: true) == "None")
        #expect(shortcutDisplayString(.unbound, numbered: false) == "None")
    }
}
