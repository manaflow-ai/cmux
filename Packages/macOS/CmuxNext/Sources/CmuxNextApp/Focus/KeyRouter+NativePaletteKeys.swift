import AppKit
import CmuxNextActions
import WebKit

// The native palettes own their keys in every web view (Lawrence 2026-10-19: "All the web views
// should not have a built-in Cmd-P or Cmd-Shift-P. They should all use the Swift version").
//
// In a cmux main window the dispatcher already decides every chord before WebKit or Chromium sees
// it (`dispatch`), and the palette actions are system and navigation tier, so they run from any
// page, agent chat, editor or field there. Other windows of the app that host web content (the
// floating Start Agent chat, a browser popup, a Chromium page window in a panel) never reached the
// dispatcher: their pages got Cmd-P and Cmd-Shift-P first (the floating chat kept itself on top
// with Cmd-Shift-P). This step closes that gap for every web view, whatever its host.
extension KeyRouter {
    /// The actions whose keys no web view may take: the native command palette and Go to Workspace.
    /// The keys come from the binding table, so a user rebinding moves them with the action.
    nonisolated static let nativePaletteActions: Set<ActionID> = ["commandPalette", "goToWorkspace"]

    /// Whether web content has the keyboard in `window`: a `WKWebView` (or a view inside one) is
    /// its first responder, or the window is a Chromium page window. Decided by class, not by host,
    /// so a new web view host is covered without opting in.
    static func webContentHasKeys(in window: NSWindow) -> Bool {
        if let pageClass = NSClassFromString("CefNSWindow"), window.isKind(of: pageClass) { return true }
        var view = window.firstResponder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    /// The binding `event` resolves to when it is a native palette action, with the app's
    /// focus-independent context (the key window is not a main window, so it has no focus bits).
    func nativePaletteBinding(for event: NSEvent) -> KeyBinding? {
        guard event.type == .keyDown, Self.isChord(event.modifierFlags) else { return nil }
        let context = KeyContext(bits: registry.context.subtracting(ActionContext.focusBits))
        guard let winner = resolve(event, context: context, ghostty: false), Self.nativePaletteActions.contains(winner.command) else {
            return nil
        }
        return winner
    }

    /// A palette key while web content outside a cmux main window has the keyboard: the native
    /// palette opens over the last main window and the page never gets the key-down. Returns
    /// whether it took the key. Main windows are left to ``dispatch(_:in:controller:facts:)``,
    /// which also keeps browser focus mode's rule (the page owns every key but its exit chords and Quit).
    func routesNativePaletteKey(_ event: NSEvent, in window: NSWindow?) -> Bool {
        // Cheapest first: this runs for every key-down, plain typing included.
        guard Self.isChord(event.modifierFlags), let window, Self.webContentHasKeys(in: window), focus(for: window).1 != .content,
              let winner = nativePaletteBinding(for: event) else { return false }
        decided.add(event)
        let context = KeyContext(bits: registry.context.subtracting(ActionContext.focusBits))
        let id = services?.windows.active?.state.id ?? ""
        run(Candidate(id: winner.command, tier: registry.keyTier(for: winner.command), source: .registry(argument: winner.argument),
                      arguments: winner.arguments), context: context, window: id)
        trace?("native palette: \(winner.command.rawValue) from web content outside a main window")
        return true
    }
}
