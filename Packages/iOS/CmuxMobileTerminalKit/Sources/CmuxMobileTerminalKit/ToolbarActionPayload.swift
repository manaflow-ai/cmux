public import Foundation

/// What a ``CustomToolbarAction`` sends to the terminal when tapped.
///
/// The cases cover the requests a user-defined bar button needs to express:
/// inserting a literal command or snippet (``text``) — which is how the shipped
/// agent launchers like `claude --dangerously-skip-permissions` work — and
/// firing a single modified special key such as Shift+Tab or Alt+Left
/// (``keyCombo``). A ``macro`` runs several text/key steps in order, so one
/// toolbar button can drive a multi-key terminal workflow.
public enum ToolbarActionPayload: Codable, Equatable, Sendable {
    /// Insert literal text. Newlines are normalized to carriage returns at send
    /// time (terminals expect `\r` for Return), so a trailing newline makes the
    /// action submit a command rather than just type it.
    case text(String)

    /// Send a special key with the given modifiers, encoded by
    /// ``TerminalKeyEncoder``. Only combinations the encoder defines produce
    /// output; others resolve to `nil`.
    case keyCombo(modifiers: TerminalKeyModifier, key: TerminalSpecialKey)

    /// Send several macro steps in sequence. If any step cannot be encoded, the
    /// whole macro resolves to `nil` so a malformed custom button cannot send a
    /// partial sequence.
    case macro([ToolbarActionMacroStep])

    /// The bytes sent for this payload, or `nil` when it resolves to nothing.
    public var output: Data? {
        switch self {
        case let .text(value):
            return ToolbarActionMacroStep.text(value).output
        case let .keyCombo(modifiers, key):
            return ToolbarActionMacroStep.keyCombo(modifiers: modifiers, key: key).output
        case let .macro(steps):
            guard !steps.isEmpty else { return nil }
            var sequence = Data()
            for step in steps {
                guard let output = step.output else { return nil }
                sequence.append(output)
            }
            guard !sequence.isEmpty else { return nil }
            return sequence
        }
    }
}
