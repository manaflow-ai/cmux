import AppKit
import CmuxNextActions

// A navigation chord typed while the command palette is open (P0 2026-10-31, "Ctrl-` does not work").
//
// The app's key router decides keys only for a main window's content; with the palette key, a chord ran only through
// its main-menu key equivalent (AppKit tries those before the panel gets the key-down). New Terminal Tab has no menu
// item, so a real Ctrl-` reached this panel, which dropped every chord it did not map: no action ran and the key went
// into the search field (journey ctrlbt-real-palette: v2.2.10-opt, v2.2.12-opt and the feat tip, each 1 of 1).
//
// A navigation action beats a text field (`ActionKeyTier.navigation`), so the palette runs it, as the key would from
// the window behind, after closing itself (the new terminal gets the keyboard, as after a click outside). The context
// says a text field has the keyboard, so a binding that yields to text input (Cmd-Return's checklist toggle,
// `KeyBindingDefaults.notTextInput`) stays out. Content and system chords keep their paths: system ones are menu items
// (Close, Quit) or the palette's own keys, and content chords act on what the palette covers.
extension PaletteController {
    /// Runs the navigation action `event` is bound to, after closing the palette; false when it is bound to none. The
    /// palette's own key actions (`paletteKey.*`, ``PaletteKeyMap``) never run here: they are this panel's keys.
    func runsNavigationChord(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        let keys = RegistryKeyBindings(registry)
        var context = KeyContext(bits: registry.context.subtracting(ActionContext.focusBits))
        context[KeyContext.textInputFocus] = .bool(true)
        let bits = context.bits
        let table = keys.table
        for shortcut in ActionRegistry.shortcuts(for: event) {
            guard let winner = table.resolve([shortcut], in: context, isRunnable: { keys.canPerform($0, in: bits) },
                                             accepts: { !$0.source.isGhostty && PaletteKeyMap.commands[$0.command] == nil }).winner else { continue }
            guard registry.keyTier(for: winner.command) == .navigation else { return false }
            hide()
            keys.run(winner, keyContext: bits)
            return true
        }
        return false
    }
}
