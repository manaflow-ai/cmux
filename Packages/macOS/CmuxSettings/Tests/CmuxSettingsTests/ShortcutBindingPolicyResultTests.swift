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
}
