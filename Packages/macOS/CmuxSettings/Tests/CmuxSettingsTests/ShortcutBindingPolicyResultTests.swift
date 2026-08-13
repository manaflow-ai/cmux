import Testing
@testable import CmuxSettings

@Suite struct ShortcutBindingPolicyResultTests {
    @Test func showHideRequiresCommandOptionOrControl() {
        let shiftOnly = StoredShortcut(
            first: ShortcutStroke(
                key: "j",
                command: false,
                shift: true,
                option: false,
                control: false
            )
        )

        #expect(
            ShortcutAction.showHideAllWindows.shortcutBindingPolicyResult(
                for: shiftOnly
            ) != .accepted
        )
        #expect(
            ShortcutAction.showHideAllWindows.effectivePersistedShortcut(
                shiftOnly
            ) == nil
        )
    }

    @Test func validSpacePrefixIsAcceptedForChordEvenWhenBareSinglesAreRejected() {
        let spacePrefixedChord = StoredShortcut(
            first: ShortcutStroke(key: "space"),
            second: ShortcutStroke(key: "n")
        )

        #expect(
            ShortcutAction.newTab.shortcutBindingPolicyResult(
                for: spacePrefixedChord
            ) == .accepted
        )
        #expect(
            ShortcutAction.newTab.shortcutBindingPolicyResult(
                for: StoredShortcut(first: ShortcutStroke(key: "space"))
            ) == .accepted
        )
        #expect(
            ShortcutAction.newTab.shortcutBindingPolicyResult(
                for: StoredShortcut(first: ShortcutStroke(key: "x"))
            ) == .bareFirstStrokeNotAllowed
        )
    }

    @Test func escapeSuffixIsReservedForPrefixCancellation() {
        let escapeChord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true),
            second: ShortcutStroke(key: "escape")
        )

        #expect(
            ShortcutAction.newTab.shortcutBindingPolicyResult(for: escapeChord)
                == .systemReservedShortcutNotAllowed
        )
    }
}
