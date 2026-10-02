import AppKit
import CmuxNextActions
import Testing

@Suite struct GlobalHotKeyCatalogTests {
    @Test func showHideAllWindowsIsTheSystemWideDefault() {
        let registry = ActionRegistry.standard()
        registry.bind("showHideAllWindows") {}
        #expect(registry.descriptor(for: "showHideAllWindows")?.isGlobalHotKey == true)
        #expect(registry.globalHotKeys() == ["showHideAllWindows": Shortcut(".", modifiers: [.control, .option, .command])])
    }

    @Test func onlyBoundActionsWithOneShortcutAreGlobal() {
        let registry = ActionRegistry.standard()
        #expect(registry.globalHotKeys().isEmpty)

        registry.bind("showHideAllWindows") {}
        registry.setShortcutOverride(nil, for: "showHideAllWindows")
        #expect(registry.globalHotKeys().isEmpty)
    }
}
