import CmuxNextActions
import Testing

/// Cmd-Shift-A is Search Tabs in every context but a focused Simulator
/// (Simulator's own Toggle Appearance chord); Focus TextBox moved to
/// Cmd-Opt-A so a terminal does not take the chord.
@Suite struct TabSearchShortcutTests {
    let cmdShiftA = Shortcut("a", modifiers: [.command, .shift])

    func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for id: ActionID in ["tab.search", "focusTextBoxInput", "simulatorToggleAppearance", "attachTextBoxFile"] {
            registry.bind(id) {}
        }
        return registry
    }

    @Test func searchTabsOwnsCmdShiftAOutsideTheSimulator() {
        let registry = registry()
        #expect(registry.descriptor(for: "tab.search")?.defaultShortcut == cmdShiftA)
        for context: ActionContext in [[], [.terminalFocused], [.browserFocused], [.terminalFocused, .textBoxFocused]] {
            registry.context = context
            #expect(registry.keyWinner(cmdShiftA)?.command == "tab.search", "context \(context.rawValue)")
        }
        registry.context = [.simulatorFocused]
        #expect(registry.keyWinner(cmdShiftA)?.command == "simulatorToggleAppearance")
    }

    @Test func focusTextBoxMovedToCmdOptA() {
        let registry = registry()
        registry.context = [.terminalFocused]
        #expect(registry.keyWinner(Shortcut("a", modifiers: [.command, .option]))?.command == "focusTextBoxInput")
        #expect(registry.keyWinner(Shortcut("a", modifiers: [.command, .option, .shift]))?.command == "attachTextBoxFile")
        #expect(!registry.shortcutConflicts().contains { $0.contains("tab.search") || $0.contains("focusTextBoxInput") })
    }

    @Test func searchTabsIsOnThePaletteTheCLIAndMCPButNoObjectMenu() {
        let registry = ActionRegistry.standard()
        let descriptor = registry.descriptor(for: "tab.search")
        #expect(descriptor?.cliName == "tab search")
        #expect(descriptor?.isPaletteVisible == true)
        #expect(descriptor?.surfacePlan.cli == .offered)
        #expect(descriptor?.surfacePlan.mcpExemption == nil)
        #expect(descriptor?.surfacePlan.contextMenuExemption == .focusMove)
        #expect(descriptor?.arguments.first { $0.name == "query" }?.isRequired == false)
        #expect(descriptor?.targets == [.tab])
    }

    /// Go to Tab… is Search Tabs now: one tab list. The old id still binds
    /// and runs it, so cmux.json bindings and scripts keep working.
    @Test func goToTabIsAnAliasOfSearchTabs() {
        let registry = ActionRegistry.standard()
        #expect(registry.canonicalID(for: "palette.goToTab") == "tab.search")
        #expect(registry.descriptor(for: "palette.goToTab")?.id == "tab.search")
        #expect(!registry.descriptors.contains { $0.id == "palette.goToTab" })
        var runs = 0
        registry.bind("palette.goToTab") { runs += 1 }
        #expect(registry.perform("tab.search"))
        #expect(runs == 1)
    }
}
