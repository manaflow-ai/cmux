import Testing
import CmuxSettings
@testable import CmuxSettingsUI

@Suite("Numbered-aware shortcut conflict detection")
struct ShortcutConflictTests {
    private func stroke(
        _ key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> ShortcutStroke {
        ShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
    }

    @Test func numberedFamilyConflictsWithExactSameModifierDigit() {
        // Codex regression: recording ⌃⌥<digit> for a numbered action must
        // collide with an existing exact ⌃⌥5 binding, even though the recorded
        // digit is normalized to the "1" placeholder before comparison.
        #expect(
            numberedAwareStrokesConflict(
                stroke("1", option: true, control: true), numbered: true,
                stroke("5", option: true, control: true), numbered: false
            )
        )
    }

    @Test func exactDigitConflictsWithNumberedFamily() {
        // Reverse direction: recording exact ⌃⌥5 collides with an existing
        // numbered ⌃⌥1…9 family.
        #expect(
            numberedAwareStrokesConflict(
                stroke("5", option: true, control: true), numbered: false,
                stroke("1", option: true, control: true), numbered: true
            )
        )
    }

    @Test func twoNumberedFamiliesConflictOnlyWhenModifiersMatch() {
        #expect(
            numberedAwareStrokesConflict(
                stroke("1", control: true), numbered: true,
                stroke("1", control: true), numbered: true
            )
        )
        #expect(
            !numberedAwareStrokesConflict(
                stroke("1", control: true), numbered: true,
                stroke("1", command: true), numbered: true
            )
        )
    }

    @Test func numberedFamilyDoesNotConflictWithNonDigitKey() {
        // ⌃T is not part of the digit family, so no collision.
        #expect(
            !numberedAwareStrokesConflict(
                stroke("1", control: true), numbered: true,
                stroke("t", control: true), numbered: false
            )
        )
    }

    @Test func exactBindingsUseLiteralEquality() {
        #expect(
            numberedAwareStrokesConflict(
                stroke("w", command: true), numbered: false,
                stroke("w", command: true), numbered: false
            )
        )
        #expect(
            !numberedAwareStrokesConflict(
                stroke("w", command: true), numbered: false,
                stroke("e", command: true), numbered: false
            )
        )
    }
}
