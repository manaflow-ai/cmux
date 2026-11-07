import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextFocusUI

// Keys in windows that are not cmux main windows, which the dispatcher (`dispatch`) never decides.
//
// The native palettes own their keys in every web view (Lawrence 2026-10-19: "All the web views
// should not have a built-in Cmd-P or Cmd-Shift-P. They should all use the Swift version").
// Other windows of the app that host web content (the floating Start Agent chat, a browser popup,
// a Chromium page window in a panel) gave Cmd-P and Cmd-Shift-P to their pages.
//
// A first-run tool window (Agents, Import from Browser, Computer Use setup) is key in front of the
// main window and has no text input. A shortcut with no menu item (Ctrl-` New Terminal Tab) did
// nothing there (P0 ctrlbt-real-palette, the Agents window of #36372): it runs in the main window.
extension KeyRouter {
    /// The actions whose keys no web view may take: the native command palette and Go to Workspace.
    /// The keys come from the binding table, so a user rebinding moves them with the action.
    nonisolated static let nativePaletteActions: Set<ActionID> = ["commandPalette", "goToWorkspace"]

    /// A chord's binding with the app's focus-independent context (no main window is key); never a Ghostty keybind.
    private func bindingOutsideMainWindow(_ event: NSEvent) -> KeyBinding? {
        guard event.type == .keyDown, Self.isChord(event.modifierFlags) else { return nil }
        return resolve(event, context: KeyContext(bits: registry.context.subtracting(ActionContext.focusBits)), ghostty: false)
    }

    /// A palette key while web content outside a cmux main window has the keyboard: the native
    /// palette opens over the last main window and the page never gets the key-down. Returns
    /// whether it took the key. Main windows are left to ``dispatch(_:in:controller:facts:)``,
    /// which also keeps browser focus mode's rule (the page owns every key but its exit chords and Quit).
    func routesNativePaletteKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        // Cheapest first: this runs for every key-down, plain typing included.
        guard Self.isChord(event.modifierFlags), let window, window.webContentHasKeys, focus(for: window).1 != .content,
              let winner = bindingOutsideMainWindow(event), Self.nativePaletteActions.contains(winner.command) else { return false }
        runInMainWindow(winner, event, raise: false)
        return true
    }

    /// A keyboard-only cmux shortcut in an onboarding tool window: the last main window comes forward
    /// and the action runs there. Menu actions (close, app-level) and destructive ones are left to the
    /// menu and ``WindowKeyTable`` as before; text input and typing stay with the window.
    func routesToolWindowKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        guard let window, window.windowKind == .onboarding, !(window.firstResponder is NSText), let winner = bindingOutsideMainWindow(event),
              registry.keyTier(for: winner.command) != .content, registry.descriptor(for: winner.command)?.surfaces.contains(.menu) != true,
              WindowKeyTable(registry: registry).behavior(for: winner.command, in: .onboarding) == .run else { return false }
        runInMainWindow(winner, event, raise: true)
        return true
    }

    /// Runs `winner` for the last main window; the window hook and the menu run nothing more for `event`.
    private func runInMainWindow(_ winner: KeyBinding, _ event: NSEvent, raise: Bool) {
        decided.add(event)
        let main = services?.windows.active
        if raise, let shown = main?.window { WindowActivation.show(shown, .raise) }
        run(Candidate(id: winner.command, tier: registry.keyTier(for: winner.command), source: .registry(argument: winner.argument),
                      arguments: winner.arguments), context: KeyContext(bits: registry.context.subtracting(ActionContext.focusBits)), window: main?.state.id ?? "")
        trace?("\(winner.command.rawValue) from a key outside a main window")
    }
}
