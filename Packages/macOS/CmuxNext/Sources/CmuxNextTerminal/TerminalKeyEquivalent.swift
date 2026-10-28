public import AppKit
import GhosttyNextKit

/// A terminal's key equivalents, which reach it before the main menu
/// (split from `TerminalSurfaceView`). Ghostty keybinds run here, except
/// that a cmux menu item with the same chord wins (the app's menu gate
/// refuses a key its dispatcher already decided), so cmux shortcuts are
/// never shadowed by Ghostty defaults such as `cmd+t`. Unbound Command and
/// Control chords go back through `keyDown` after AppKit had its chance.
public struct TerminalKeyEquivalent {
    public let view: TerminalSurfaceView

    /// Whether the main menu may take `event` before Ghostty. The app says no
    /// for a key its dispatcher already decided (it gave the key to this
    /// terminal): a refused menu item still claims its key equivalent, so
    /// asking the menu would swallow the user's Ghostty keybind (nxdog50).
    public static var menuMayClaim: ((NSEvent) -> Bool)?

    /// Whether the dispatcher gave `event` to this terminal for the user's
    /// own Ghostty keybind (their config binds a chord cmux has a default on,
    /// or binds a routed action). Then no main-menu item takes a Command
    /// chord before Ghostty. Ghostty's and cmux's default keybinds never
    /// count, so Edit > Undo keeps Cmd-Z. An unbind still lets AppKit offer
    /// the menu after Ghostty declines the key.
    public static var userKeybindOwns: ((NSEvent) -> Bool)?

    /// Notes the path of a traced key (`debug.key`); nil otherwise.
    public static var trace: ((String) -> Void)?

    /// Sends a Command chord (`super+z`) to the terminal's program, encoded by the PTY owner
    /// with the program's own keyboard modes (the daemon's `send-key`, as the shipping cmux
    /// sends `super+c` by name). Returns false when the session has no daemon terminal; `fallback`
    /// runs on the main actor when the daemon refused the key unsent (an older machine daemon).
    /// The chord travels as a daemon command, not on the attach link that carries typing.
    public static var sendToProgram: ((TerminalSession, String, _ fallback: @escaping @MainActor () -> Void) -> Bool)?

    public init(view: TerminalSurfaceView) {
        self.view = view
    }

    public func perform(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, view.isFirstResponder, let surface = view.surface else { return false }

        // A TUI that reads the mouse (Claude Code fullscreen, OpenCode, Codex) owns its editing
        // chords: Cmd-Z / Cmd-Shift-Z undo and redo its input and Cmd-A selects it, so they go to
        // the program instead of Edit > Undo, Redo and Select All (a shell keeps those). The
        // user's own Ghostty keybind on the chord still wins.
        if let chord = Self.programChord(event), view.programCapturesMouse, !(Self.userKeybindOwns?(event) ?? false),
           let session = view.session, Self.sendToProgram?(session, chord, {}) == true {
            Self.trace?("terminal: \(chord) to the program")
            return true
        }

        // App-level Command actions, especially Quit, must win before a
        // Ghostty binding or an unbound chord can forward text to the PTY,
        // unless the dispatcher gave this key to the terminal for the user's
        // own Ghostty keybind: then the menu never takes it first.
        if event.modifierFlags.contains(.command), !(Self.userKeybindOwns?(event) ?? false),
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }

        var flags = ghostty_binding_flags_e(rawValue: 0)
        var keyEvent = GhosttyInput.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        let isBinding = (event.characters ?? "").withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
        Self.trace?("terminal: Ghostty binding \(isBinding ? "yes" : "no")")
        if isBinding {
            if Self.menuMayClaim?(event) ?? true, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                Self.trace?("terminal: the menu took it")
                return true
            }
            Self.trace?("terminal: keyDown to Ghostty")
            view.keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            // Ctrl-Return goes to the terminal instead of the default button.
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            // Ctrl-/ is Ctrl-_ in terminals; AppKit would beep.
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            // Synthetic events (zero timestamp) come from AppKit key
            // bindings such as Cmd-. -> cancel; never encode those.
            guard event.timestamp != 0 else { return false }
            guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                view.lastPerformKeyEventTimestamp = nil
                return false
            }
            // Second pass for the same event: nothing in AppKit claimed it,
            // so encode it for the terminal.
            if let previous = view.lastPerformKeyEventTimestamp {
                view.lastPerformKeyEventTimestamp = nil
                if previous == event.timestamp {
                    equivalent = event.characters ?? ""
                    break
                }
            }
            view.lastPerformKeyEventTimestamp = event.timestamp
            return false
        }

        guard let rewritten = NSEvent.keyEvent(
            with: .keyDown,
            location: event.locationInWindow,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: equivalent,
            charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) else { return false }
        view.keyDown(with: rewritten)
        return true
    }

    /// The program's name for a Command chord a TUI that reads the mouse owns, nil for any other
    /// key (Cmd-C goes through `TerminalSurfaceView.copy`, Cmd-K through `terminal.clear`).
    static func programChord(_ event: NSEvent) -> String? {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch (event.charactersIgnoringModifiers?.lowercased(), modifiers) {
        case ("z", [.command]): return "super+z"
        case ("z", [.command, .shift]): return "super+shift+z"
        case ("a", [.command]): return "super+a"
        default: return nil
        }
    }
}
