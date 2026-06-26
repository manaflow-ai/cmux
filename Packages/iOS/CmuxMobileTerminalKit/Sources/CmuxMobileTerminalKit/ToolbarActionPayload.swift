/// What a ``CustomToolbarAction`` or ``ToolbarMenuItem`` sends when selected.
///
/// The two cases cover the requests a user-defined bar button needs to express:
/// inserting a literal command or snippet (``text``) — which is how the shipped
/// agent launchers like `claude --dangerously-skip-permissions` work — and
/// firing a single modified special key such as Shift+Tab or Alt+Left
/// (``keyCombo``). A menu payload turns the toolbar button into a dropdown whose
/// children each carry their own payload.
public indirect enum ToolbarActionPayload: Codable, Equatable, Sendable {
    /// Insert literal text. Newlines are normalized to carriage returns at send
    /// time (terminals expect `\r` for Return), so a trailing newline makes the
    /// action submit a command rather than just type it.
    case text(String)

    /// Send a special key with the given modifiers, encoded by
    /// ``TerminalKeyEncoder``. Only combinations the encoder defines produce
    /// output; others resolve to `nil`.
    case keyCombo(modifiers: TerminalKeyModifier, key: TerminalSpecialKey)

    /// Open a dropdown menu of related toolbar actions.
    case menu([ToolbarMenuItem])

    /// Whether this payload represents a dropdown menu instead of direct output.
    public var isMenu: Bool {
        if case .menu = self { return true }
        return false
    }
}
