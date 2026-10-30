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
///
/// Ghostty matches links for Command alone, so Shift-Command (the browser the link setting does not
/// pick) and Option-Command (a browser profile) matched none. A move with one of them, and a press on
/// a link with its drags and release, go as Command alone, or as Command with the Shift override
/// while the program has the mouse; the open reads the real keys from the event.
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

    /// Command with Shift or Option, without Control or Fn: a link click that picks where it opens.
    static func commandChord(_ flags: NSEvent.ModifierFlags) -> Bool {
        let keys = flags.intersection([.command, .shift, .control, .option, .function])
        return keys.contains(.command) && keys != .command && keys.isSubset(of: [.command, .shift, .option])
    }

    /// Whether this event goes as a link gesture of a Command chord (Shift- or Option-Command).
    func chordGesture(_ flags: NSEvent.ModifierFlags, phase: Phase) -> Bool {
        guard Self.commandChord(flags) else { return phase == .followingPress && linkPress && !captured }
        switch phase {
        case .move: return true
        case .press: return overLink
        case .followingPress: return linkPress
        }
    }

    /// Whether this event goes as a link gesture: with Shift added to its keys.
    func linkGesture(_ flags: NSEvent.ModifierFlags, phase: Phase) -> Bool {
        guard captured, Self.commandOnly(flags) else { return phase == .followingPress && linkPress && captured }
        switch phase {
        case .move: return true
        case .press: return overLink
        case .followingPress: return linkPress
        }
    }

    /// `flags` with Shift added when ``linkGesture(_:phase:)`` holds, as Command alone when
    /// ``chordGesture(_:phase:)`` does.
    func flags(_ flags: NSEvent.ModifierFlags, phase: Phase) -> NSEvent.ModifierFlags {
        let chord: NSEvent.ModifierFlags = captured ? [.command, .shift] : .command
        // A chord first: with Option kept, Ghostty would match no link even with the Shift override.
        if Self.commandChord(flags), chordGesture(flags, phase: phase) { return chord }
        if linkGesture(flags, phase: phase) { return flags.union(.shift) }
        if chordGesture(flags, phase: phase) { return chord }
        return flags
    }
}
