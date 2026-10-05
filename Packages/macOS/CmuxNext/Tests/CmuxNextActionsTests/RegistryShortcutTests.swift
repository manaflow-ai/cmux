import AppKit
import CmuxNextActions
import Testing

@Suite struct RegistryShortcutTests {
    @Test func legacyIDsFoldIntoCatalogIDs() {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.register(Action(id: "tab.new", title: "New Tab", shortcut: Shortcut("t")) { ran = true })

        #expect(registry.isBound("newSurface"))
        #expect(registry.action(for: "tab.new")?.id == "newSurface")
        #expect(registry.perform("newSurface"))
        #expect(ran)
        // One entry, not a catalog row plus an uncatalogued duplicate.
        #expect(registry.entries.filter { $0.id == "newSurface" }.count == 1)
        #expect(!registry.entries.contains { $0.id == "tab.new" })
    }

    /// Cmd-[ is page Back only (plans/cmux-next/history.md 4.1); the
    /// location trail's Go Back is Ctrl-Cmd-Left in every context.
    @Test func bracketIsPageBackAndGoBackHasItsOwnChord() {
        let registry = ActionRegistry.standard()
        var hits: [String] = []
        registry.bind("focusHistoryBack") { hits.append("history") }
        registry.bind("browserBack") { hits.append("browser") }
        let cmdBracket = Shortcut("[", modifiers: [.command])
        let goBack = Shortcut(Shortcut.leftArrowKey, modifiers: [.control, .command])

        #expect(registry.keyWinner(cmdBracket)?.command != "focusHistoryBack")
        #expect(registry.keyWinner(goBack)?.command == "focusHistoryBack")
        registry.context = [.browserFocused]
        #expect(registry.keyWinner(cmdBracket)?.command == "browserBack")
        #expect(registry.performKey(cmdBracket))
        #expect(registry.keyWinner(goBack)?.command == "focusHistoryBack")
        #expect(registry.performKey(goBack))
        #expect(hits == ["browser", "history"])
    }

    @Test func unavailableOrUnboundActionsDoNotRun() {
        let registry = ActionRegistry.standard()
        var ran = false
        registry.bind("browserReload") { ran = true }
        #expect(!registry.perform("browserReload"))  // needs browser focus
        #expect(!registry.perform("splitRight"))  // not bound
        registry.context = [.browserFocused]
        #expect(registry.perform("browserReload"))
        #expect(ran)
    }

    @Test func digitFamilyPassesTheDigit() {
        let registry = ActionRegistry.standard()
        var selected: [String] = []
        registry.bind("selectWorkspaceByNumber", argumentHandler: { selected.append($0) }) {}
        let resolved = registry.keyWinner(Shortcut("3", modifiers: [.command]))
        #expect(resolved?.command == "selectWorkspaceByNumber")
        #expect(resolved?.argument == "3")
        #expect(registry.performKey(Shortcut("7", modifiers: [.command])))
        #expect(selected == ["7"])
        #expect(registry.shortcutDisplay(for: "selectWorkspaceByNumber") == "⌘1…9")
    }

    @Test func paneResizeUsesControlCommandArrowsAndVimKeys() {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["resizePaneLeft", "resizePaneRight", "resizePaneUp", "resizePaneDown"] {
            registry.bind(id) {}
        }
        registry.bind("focusHistoryBack") {}
        registry.bind("focusHistoryForward") {}

        let expected: [(Shortcut, ActionID)] = [
            (Shortcut(Shortcut.leftArrowKey, modifiers: [.control, .command]), "resizePaneLeft"),
            (Shortcut(Shortcut.rightArrowKey, modifiers: [.control, .command]), "resizePaneRight"),
            (Shortcut(Shortcut.upArrowKey, modifiers: [.control, .command]), "resizePaneUp"),
            (Shortcut(Shortcut.downArrowKey, modifiers: [.control, .command]), "resizePaneDown"),
            (Shortcut("h", modifiers: [.control, .command]), "resizePaneLeft"),
            (Shortcut("l", modifiers: [.control, .command]), "resizePaneRight"),
            (Shortcut("k", modifiers: [.control, .command]), "resizePaneUp"),
            (Shortcut("j", modifiers: [.control, .command]), "resizePaneDown"),
        ]
        for (shortcut, action) in expected {
            #expect(registry.resolve(shortcut)?.id == action, "Expected \(shortcut.displayString) to resolve to \(action)")
        }

        for key in ["h", "j", "k", "l"] {
            #expect(registry.resolve(Shortcut(key, modifiers: [.control, .shift])) == nil)
        }

        #expect(registry.resolve(Shortcut("-", modifiers: [.control]))?.id == "focusHistoryBack")
        #expect(registry.resolve(Shortcut("-", modifiers: [.control, .shift]))?.id == "focusHistoryForward")
    }

    @Test func overridesDriveResolutionAndDisplay() {
        let registry = ActionRegistry.standard()
        registry.bind("splitRight") {}
        #expect(registry.shortcutDisplay(for: "splitRight") == "⌘D")

        registry.setShortcutOverride(Shortcut("\\", modifiers: [.command]), for: "splitRight")
        #expect(registry.keyWinner(Shortcut("\\", modifiers: [.command]))?.command == "splitRight")
        #expect(registry.keyWinner(Shortcut("d", modifiers: [.command])) == nil)
        #expect(registry.shortcutDisplay(for: "splitRight") == "⌘\\")

        registry.setShortcutOverride(nil, for: "splitRight")
        #expect(registry.effectiveShortcut(for: "splitRight") == nil)
        #expect(registry.shortcutDisplay(for: "splitRight") == nil)

        registry.removeShortcutOverride(for: "splitRight")
        #expect(registry.shortcutDisplay(for: "splitRight") == "⌘D")
    }

    @Test func displayStrings() {
        let registry = ActionRegistry.standard()
        #expect(registry.shortcutDisplay(for: "commandPalette") == "⇧⌘P")
        #expect(registry.shortcutDisplay(for: "focusLeft") == "⌥⌘←")
        #expect(registry.shortcutDisplay(for: "toggleSplitZoom") == "⇧⌘↩")
        #expect(registry.shortcutDisplay(for: "closeWindow") == "⌃⌘W")
        #expect(registry.shortcutDisplay(for: "diffViewerGoToTop") == "g g")
        #expect(registry.shortcutKeycaps(for: "commandPalette") == ["⇧", "⌘", "P"])
    }

    @Test func menuItemUsesEffectiveShortcutAndCatalogTitle() throws {
        let registry = ActionRegistry.standard()
        registry.bind("splitDown") {}
        let item = try #require(registry.makeMenuItem(for: "splitDown"))
        #expect(item.keyEquivalent == "d")
        #expect(item.keyEquivalentModifierMask == [.command, .shift])
        #expect(item.title == registry.title(for: "splitDown"))
    }

    @Test func argumentHandlerReceivesText() {
        let registry = ActionRegistry.standard()
        var names: [String] = []
        registry.bind("renameTab", argumentHandler: { names.append($0) }) {}
        #expect(registry.perform("renameTab", argument: "api"))
        #expect(names == ["api"])
    }
}
