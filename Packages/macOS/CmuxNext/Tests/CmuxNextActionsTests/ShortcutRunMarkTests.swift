import CmuxNextActions
import Testing

/// A key binding's run says so (`ActionInvocation.byShortcut`): New Terminal Tab's Ctrl-` reads it
/// to open a tab in the focused workspace whatever `newTerminal.opensWorkspace` says, while the
/// New Terminal controls, menu items and palette rows follow the setting
/// (https://github.com/manaflow-ai/cmux/issues/34431).
@MainActor @Suite struct ShortcutRunMarkTests {
    @Test func aKeyBindingRunIsMarkedAndADirectRunIsNot() {
        let registry = ActionRegistry.standard()
        var runs: [ActionInvocation] = []
        registry.bind("newSurface", invoke: { runs.append($0) })

        RegistryKeyBindings(registry).run(KeyBinding(keys: [], command: "newSurface"), keyContext: registry.context)
        #expect(registry.perform("newSurface", invocation: ActionInvocation()))

        #expect(runs.map(\.byShortcut) == [true, false], "Ctrl-` is not told apart from a click on New Terminal")
    }
}
