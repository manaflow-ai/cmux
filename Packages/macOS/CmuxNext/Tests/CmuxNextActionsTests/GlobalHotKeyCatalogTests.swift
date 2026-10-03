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

    /// Quick Agent Chat summons its panel from any app on Ctrl-Opt-Cmd-Space,
    /// and is on the palette, the menu bar and the CLI too.
    @Test func quickAgentChatIsGlobalOnControlOptionCommandSpace() throws {
        let registry = ActionRegistry.standard()
        registry.bind("palette.quickAgentChat") {}
        let descriptor = try #require(registry.descriptor(for: "palette.quickAgentChat"))
        #expect(descriptor.isGlobalHotKey)
        #expect(descriptor.cliName == "agent quick")
        #expect(descriptor.surfaces.isSuperset(of: [.palette, .keyboard, .menu]))
        #expect(descriptor.mainMenu != nil)
        let space = Shortcut(Shortcut.spaceKey, modifiers: [.control, .option, .command])
        #expect(registry.globalHotKeys() == ["palette.quickAgentChat": space])

        registry.bind("showHideAllWindows") {}
        #expect(registry.globalHotKeys().count == 2)
    }

    @Test func unboundRemovedOrChordedActionsAreNotGlobal() {
        let registry = ActionRegistry.standard()
        #expect(registry.globalHotKeys().isEmpty)

        registry.bind("showHideAllWindows") {}
        registry.setShortcutOverride(nil, for: "showHideAllWindows")
        #expect(registry.globalHotKeys().isEmpty)

        registry.setChordOverride(ShortcutChord(Shortcut("b", modifiers: [.control]), Shortcut("h", modifiers: [])), for: "showHideAllWindows")
        #expect(registry.globalHotKeys().isEmpty)

        registry.removeShortcutOverride(for: "showHideAllWindows")
        #expect(registry.globalHotKeys().count == 1)
    }
}
