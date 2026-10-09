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

    /// Start Agent (`palette.quickAgentChat`, cx-hkat) is an in-app key,
    /// Ctrl-Cmd-Return; its system-wide key is a separate action, Start
    /// Agent from Any App, on Ctrl-Opt-Cmd-Space, so each has its own
    /// recorder and the global one can stay off (`app.startAgentGlobalHotKey`).
    @Test func startAgentIsInAppAndItsGlobalKeyIsASeparateAction() throws {
        let registry = ActionRegistry.standard()
        registry.bind("palette.quickAgentChat") {}
        registry.bind("palette.startAgentFromAnyApp") {}
        let start = try #require(registry.descriptor(for: "palette.quickAgentChat"))
        #expect(start.title == "Start Agent…")
        #expect(!start.isGlobalHotKey)
        #expect(start.defaultShortcut == Shortcut(Shortcut.returnKey, modifiers: [.control, .command]))
        #expect(start.keywords.contains("quick") && start.keywords.contains("chat") && start.keywords.contains("start"))
        #expect(start.cliName == "agent quick")
        #expect(start.surfaces.isSuperset(of: [.palette, .keyboard, .menu]))
        #expect(start.mainMenu != nil)

        let anyApp = try #require(registry.descriptor(for: "palette.startAgentFromAnyApp"))
        #expect(anyApp.isGlobalHotKey)
        #expect(anyApp.surfaces == [.keyboard])
        let space = Shortcut(Shortcut.spaceKey, modifiers: [.control, .option, .command])
        #expect(registry.globalHotKeys() == ["palette.startAgentFromAnyApp": space])

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
