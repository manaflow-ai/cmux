import Testing
@testable import CmuxSettings

@Suite
struct CopyUnwrappedShortcutTests {
    @Test func explicitCopyModeBindingOutranksCopyUnwrappedDefault() throws {
        let commandShiftC = try #require(ShortcutKeymapBinding.stroke("cmd+shift+c").shortcut)
        let action = ShortcutAction.copyUnwrapped
        let resolve: (StoredShortcut?, StoredShortcut?) -> StoredShortcut? = { candidate, copyMode in
            action.effectivePersistedShortcutResolvingLegacyConflicts(
                candidate,
                explicitlyConfiguredShortcut: { $0 == .toggleTerminalCopyMode ? copyMode : nil },
                bindingsConflict: { proposed, _, configured in proposed == configured }
            )
        }
        #expect(resolve(nil, nil) == commandShiftC)
        #expect(resolve(nil, commandShiftC) == nil)
        #expect(resolve(commandShiftC, commandShiftC) == commandShiftC)
        #expect(resolve(nil, .unbound) == commandShiftC)
    }

    @Test func copyUnwrappedAllowsFocusedDockTerminal() {
        let dock = ShortcutFocusState(browser: false, markdown: false, sidebar: true)
        #expect(ShortcutAction.copyUnwrapped.defaultFocusWhenClause.evaluate(dock))
        let browser = ShortcutFocusState(browser: true, markdown: false, sidebar: false)
        #expect(!ShortcutAction.copyUnwrapped.defaultFocusWhenClause.evaluate(browser))
    }
}
