public import Foundation

/// What a ``CustomToolbarAction`` or ``ToolbarMenuItem`` sends when selected.
///
/// The two cases cover the requests a user-defined bar button needs to express:
/// inserting a literal command or snippet (``text``) — which is how the shipped
/// agent launchers like `claude --dangerously-skip-permissions` work — and
/// firing a single modified special key such as Shift+Tab or Alt+Left
/// (``keyCombo``). A menu payload turns the toolbar button into a dropdown whose
/// children each carry their own payload.
///
/// The selection encoding (``output``) and menu accessors (``menuItems``,
/// ``isMenu``) live on this payload so ``CustomToolbarAction`` and
/// ``ToolbarMenuItem`` share one implementation instead of each re-deriving the
/// same bytes.
public enum ToolbarActionPayload: Codable, Equatable, Sendable {
    /// Insert literal text. Newlines are normalized to carriage returns at send
    /// time (terminals expect `\r` for Return), so a trailing newline makes the
    /// action submit a command rather than just type it.
    case text(String)

    /// Send a special key with the given modifiers, encoded by
    /// ``TerminalKeyEncoder``. Only combinations the encoder defines produce
    /// output; others resolve to `nil`.
    case keyCombo(modifiers: TerminalKeyModifier, key: TerminalSpecialKey)

    /// Open a dropdown menu of related toolbar actions. Only this recursive case
    /// needs boxing, so indirection is applied here rather than to the whole enum
    /// (the common ``text``/``keyCombo`` cases stay inline).
    indirect case menu([ToolbarMenuItem])

    /// Whether this payload represents a dropdown menu instead of direct output.
    public var isMenu: Bool {
        if case .menu = self { return true }
        return false
    }
}

extension ToolbarActionPayload {
    /// The bytes sent to the terminal when a control carrying this payload is
    /// selected, or `nil` when the payload is a submenu or resolves to no bytes
    /// (empty text, or an unencodable key combo).
    ///
    /// For ``text(_:)`` newlines are normalized to carriage returns, matching the
    /// terminal input pipeline's Return handling. `\r\n` is collapsed to a single
    /// `\r` first so CRLF text (e.g. pasted or imported) does not send a double
    /// Return.
    public var output: Data? {
        switch self {
        case let .text(value):
            let normalized = value
                .replacingOccurrences(of: "\r\n", with: "\r")
                .replacingOccurrences(of: "\n", with: "\r")
            guard !normalized.isEmpty else { return nil }
            return Data(normalized.utf8)
        case let .keyCombo(modifiers, key):
            return TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers)
        case .menu:
            return nil
        }
    }

    /// Child rows when this payload opens a dropdown menu, otherwise an empty array.
    public var menuItems: [ToolbarMenuItem] {
        if case let .menu(items) = self { return items }
        return []
    }
}
