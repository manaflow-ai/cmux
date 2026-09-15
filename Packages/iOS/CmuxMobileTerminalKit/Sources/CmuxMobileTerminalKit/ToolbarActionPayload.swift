/// What a ``CustomToolbarAction`` sends to the terminal when tapped.
///
/// The cases cover the requests a user-defined bar button needs to express:
/// inserting a literal command or snippet (``text``) — which is how the shipped
/// agent launchers like `claude --dangerously-skip-permissions` work — firing a
/// single modified special key such as Shift+Tab or Alt+Left (``keyCombo``), and
/// chaining several of those into a ``macro`` so one tap can run a short sequence
/// (e.g. rotating an agent's permission mode). All resolve to bytes through
/// ``CustomToolbarAction/output``.
public enum ToolbarActionPayload: Codable, Equatable, Sendable {
    /// Insert literal text. Newlines are normalized to carriage returns at send
    /// time (terminals expect `\r` for Return), so a trailing newline makes the
    /// action submit a command rather than just type it.
    case text(String)

    /// Send a special key with the given modifiers, encoded by
    /// ``TerminalKeyEncoder``. Only combinations the encoder defines produce
    /// output; others resolve to `nil`.
    case keyCombo(modifiers: TerminalKeyModifier, key: TerminalSpecialKey)

    /// Fire an ordered sequence of ``ToolbarMacroStep``s — text snippets and/or
    /// modified special keys — concatenated into one write. Steps that resolve to
    /// no bytes are skipped; a macro with no resolvable steps produces no output.
    case macro([ToolbarMacroStep])
}
