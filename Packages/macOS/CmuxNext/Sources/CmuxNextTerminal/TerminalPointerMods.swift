import AppKit

/// The keys Ghostty gets with a pointer event, so a Cmd-click on a link opens it in cmux even
/// while the program has the mouse (u11857).
///
/// A program that turned mouse reporting on (Claude Code, Codex, vim with `mouse=a`) gets every
/// click, and Ghostty then looks for links only with Shift held: a Cmd-hover underlined nothing
/// and a Cmd-click on `perf-status.md` went to Claude Code, which opened Finder with
/// `/usr/bin/open`. Mouse reports cannot carry Command, so a program never tells a Cmd-click
/// from a plain one. With Command alone held, a pointer move goes with Shift added (Ghostty's
/// own override of the program's capture, which it drops again before matching a link): Ghostty
/// finds the link under the pointer. A press on that link goes with Shift too, so the link opens
/// through the app and the program gets no click; its drags and release follow the press.
/// Anywhere else, and with any other key held, the click stays the program's.
nonisolated struct TerminalPointerMods: Equatable {
    /// What the pointer does.
    enum Phase: Equatable {
        /// A move with no button held.
        case move
        /// A left press.
        case press
        /// A move or release while a button is held, after the press.
        case followingPress
    }

    /// The program has the mouse (`ghostty_surface_mouse_captured`).
    var captured: Bool
    /// Ghostty reports a link under the pointer (its `mouse_over_link`).
    var overLink: Bool
    /// The press of this click went as a link click (``TerminalSurfaceView/linkPressInCapture``).
    var linkPress: Bool

    /// True when Command is the only key of `flags` held (Caps Lock aside).
    static func commandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .control, .option, .function]) == .command
    }

    /// Whether this event goes as a link gesture: with Shift added to its keys.
    func linkGesture(_ flags: NSEvent.ModifierFlags, phase: Phase) -> Bool {
        guard captured, Self.commandOnly(flags) else { return phase == .followingPress && linkPress }
        switch phase {
        case .move: return true
        case .press: return overLink
        case .followingPress: return linkPress
        }
    }

    /// `flags` with Shift added when ``linkGesture(_:phase:)`` holds.
    func flags(_ flags: NSEvent.ModifierFlags, phase: Phase) -> NSEvent.ModifierFlags {
        linkGesture(flags, phase: phase) ? flags.union(.shift) : flags
    }
}
