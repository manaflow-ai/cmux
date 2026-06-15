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

@Suite("Legacy surface-selection binding derivation")
struct LegacySurfaceSelectionShortcutTests {
    private func stroke(
        _ key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false,
        keyCode: UInt16? = nil
    ) -> ShortcutStroke {
        ShortcutStroke(
            key: key,
            command: command,
            shift: shift,
            option: option,
            control: control,
            keyCode: keyCode
        )
    }

    @Test func nonSurfaceActionDoesNotDerive() {
        #expect(
            legacySurfaceSelectionShortcut(
                for: .newTab,
                legacyBinding: StoredShortcut(first: stroke("1", control: true))
            ) == nil
        )
    }

    @Test func missingLegacyBindingDoesNotDerive() {
        // No configured legacy family → caller falls through to the per-surface
        // action's own binding or built-in default.
        #expect(legacySurfaceSelectionShortcut(for: .selectSurface3, legacyBinding: nil) == nil)
    }

    @Test func derivesPerDigitFromLegacyBindingPreservingModifiers() {
        // Legacy ⌘1 family (recorded with a virtual key code) → ⌘3 for surface 3
        // and ⌘9 for the last surface, keeping the customized ⌘ modifier rather
        // than the built-in ⌃ default and dropping the stale key code.
        let legacy = StoredShortcut(first: stroke("1", command: true, keyCode: 18))
        #expect(
            legacySurfaceSelectionShortcut(for: .selectSurface3, legacyBinding: legacy)
                == StoredShortcut(first: stroke("3", command: true))
        )
        #expect(
            legacySurfaceSelectionShortcut(for: .selectSurface9, legacyBinding: legacy)
                == StoredShortcut(first: stroke("9", command: true))
        )
    }

    @Test func explicitlyUnboundLegacyDisablesEveryPerSurfaceShortcut() {
        // A user who cleared the legacy family keeps the per-surface actions
        // unbound instead of resurrecting the ⌃-digit defaults.
        #expect(
            legacySurfaceSelectionShortcut(for: .selectSurface2, legacyBinding: .unbound)
                == .unbound
        )
    }

    @Test func chordLegacyReplacesSecondStrokeDigit() {
        // tmux-style ⌘K ⌘1 prefix → ⌘K ⌘4 for surface 4: only the second
        // stroke's digit changes; the prefix stroke is preserved.
        let legacy = StoredShortcut(
            first: stroke("k", command: true),
            second: stroke("1", command: true)
        )
        #expect(
            legacySurfaceSelectionShortcut(for: .selectSurface4, legacyBinding: legacy)
                == StoredShortcut(
                    first: stroke("k", command: true),
                    second: stroke("4", command: true)
                )
        )
    }

    @Test func derivedBindingDrivesConflictDetection() throws {
        // Regression for the autoreview finding: with a legacy ⌘1 binding the
        // settings UI resolves selectSurface3 to ⌘3, so a newly recorded ⌘3 on
        // another action collides with it — even though selectSurface3's built-in
        // default is ⌃3 and would otherwise hide the conflict.
        let derived = try #require(
            legacySurfaceSelectionShortcut(
                for: .selectSurface3,
                legacyBinding: StoredShortcut(first: stroke("1", command: true))
            )
        )
        #expect(
            numberedAwareStrokesConflict(
                stroke("3", command: true), numbered: false,
                derived.first, numbered: false
            )
        )
        // The built-in ⌃3 default no longer reflects the live binding, so a ⌃3
        // recording must not register as a conflict with the migrated surface.
        #expect(
            !numberedAwareStrokesConflict(
                stroke("3", control: true), numbered: false,
                derived.first, numbered: false
            )
        )
    }
}

@Suite("Effective stored-shortcut resolution")
struct EffectiveStoredShortcutTests {
    private func stroke(
        _ key: String,
        command: Bool = false,
        shift: Bool = false,
        option: Bool = false,
        control: Bool = false
    ) -> ShortcutStroke {
        ShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
    }

    @Test func explicitPerSurfaceBindingWinsOverLegacyFamily() {
        let bindings: [String: StoredShortcut] = [
            ShortcutAction.selectSurfaceByNumber.rawValue: StoredShortcut(first: stroke("1", command: true)),
            ShortcutAction.selectSurface3.rawValue: StoredShortcut(first: stroke("7", option: true)),
        ]
        #expect(
            effectiveStoredShortcut(for: .selectSurface3, bindings: bindings)
                == StoredShortcut(first: stroke("7", option: true))
        )
    }

    @Test func legacyFamilyBindingDrivesUnconfiguredPerSurfaceAction() {
        // Regression for the autoreview finding: with only the legacy family
        // bound to ⌘1, selectSurface3 resolves to ⌘3 (not its ⌃3 default) so
        // conflict detection sees the shortcut the app actually routes.
        let bindings: [String: StoredShortcut] = [
            ShortcutAction.selectSurfaceByNumber.rawValue: StoredShortcut(first: stroke("1", command: true))
        ]
        #expect(
            effectiveStoredShortcut(for: .selectSurface3, bindings: bindings)
                == StoredShortcut(first: stroke("3", command: true))
        )
    }

    @Test func fallsBackToBuiltInDefaultWithoutAnyConfiguration() {
        #expect(
            effectiveStoredShortcut(for: .selectSurface3, bindings: [:])
                == StoredShortcut(first: stroke("3", control: true))
        )
    }

    @Test func explicitlyUnboundLegacyFamilyDisablesUnconfiguredPerSurfaceAction() {
        // Mirrors runtime: clearing the legacy family keeps selectSurface3
        // unbound rather than resurrecting its ⌃3 default.
        #expect(
            effectiveStoredShortcut(
                for: .selectSurface3,
                bindings: [ShortcutAction.selectSurfaceByNumber.rawValue: .unbound]
            ) == .unbound
        )
    }
}
