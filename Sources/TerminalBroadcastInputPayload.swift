import CmuxTerminal
import GhosttyKit

/// A single terminal input event captured from the focused pane so it can be
/// replayed onto peer panes when workspace input broadcast is enabled.
///
/// iTerm2-style broadcast mirrors keystrokes, IME-committed text, pastes, and
/// file drops from the focused terminal to every other visible terminal pane in
/// the same workspace. Keyboard/IME input is mirrored as a faithful key event
/// (``key(action:keycode:mods:consumedMods:unshiftedCodepoint:composing:text:)``)
/// so control keys, arrows, and modifiers replay exactly; paste/drop are
/// mirrored as paste-style ``text(_:)`` so bracketed-paste semantics match the
/// source pane.
@MainActor
enum TerminalBroadcastInputPayload {
    /// A key event mirroring a physical keystroke or IME commit.
    case key(
        action: ghostty_input_action_e,
        keycode: UInt32,
        mods: ghostty_input_mods_e,
        consumedMods: ghostty_input_mods_e,
        unshiftedCodepoint: UInt32,
        composing: Bool,
        text: String?
    )

    /// Committed paste/drop text delivered through the paste path
    /// (`ghostty_surface_text`, i.e. bracketed paste when the program enables it).
    case text(String)

    /// Replays this event onto a peer terminal surface.
    func deliver(to surface: TerminalSurface) {
        switch self {
        case let .key(action, keycode, mods, consumedMods, unshiftedCodepoint, composing, text):
            surface.sendMirroredKeyEvent(
                action: action,
                keycode: keycode,
                mods: mods,
                consumedMods: consumedMods,
                unshiftedCodepoint: unshiftedCodepoint,
                composing: composing,
                text: text
            )
        case let .text(text):
            surface.sendText(text)
        }
    }
}
