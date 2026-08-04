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
                stroke("1", option: true, control: true), numberedRange: 1...9,
                stroke("5", option: true, control: true), numberedRange: nil
            )
        )
    }

    @Test func exactDigitConflictsWithNumberedFamily() {
        // Reverse direction: recording exact ⌃⌥5 collides with an existing
        // numbered ⌃⌥1…9 family.
        #expect(
            numberedAwareStrokesConflict(
                stroke("5", option: true, control: true), numberedRange: nil,
                stroke("1", option: true, control: true), numberedRange: 1...9
            )
        )
    }

    @Test func twoNumberedFamiliesConflictOnlyWhenModifiersMatch() {
        #expect(
            numberedAwareStrokesConflict(
                stroke("1", control: true), numberedRange: 1...9,
                stroke("1", control: true), numberedRange: 1...6
            )
        )
        #expect(
            !numberedAwareStrokesConflict(
                stroke("1", control: true), numberedRange: 1...9,
                stroke("1", command: true), numberedRange: 1...6
            )
        )
    }

    @Test func limitedNumberedFamilyDoesNotConflictOutsideItsRange() {
        #expect(
            !numberedAwareStrokesConflict(
                stroke("1", command: true, option: true), numberedRange: 1...6,
                stroke("7", command: true, option: true), numberedRange: nil
            )
        )
    }

    @Test func numberedFamilyDoesNotConflictWithNonDigitKey() {
        // ⌃T is not part of the digit family, so no collision.
        #expect(
            !numberedAwareStrokesConflict(
                stroke("1", control: true), numberedRange: 1...9,
                stroke("t", control: true), numberedRange: nil
            )
        )
    }

    @Test func exactBindingsUseLiteralEquality() {
        #expect(
            numberedAwareStrokesConflict(
                stroke("w", command: true), numberedRange: nil,
                stroke("w", command: true), numberedRange: nil
            )
        )
        #expect(
            !numberedAwareStrokesConflict(
                stroke("w", command: true), numberedRange: nil,
                stroke("e", command: true), numberedRange: nil
            )
        )
    }
}
