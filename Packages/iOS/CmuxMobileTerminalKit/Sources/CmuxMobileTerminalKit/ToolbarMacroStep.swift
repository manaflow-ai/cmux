public import Foundation

/// One step in a ``ToolbarActionPayload/macro(_:)`` — the unit a multi-step
/// toolbar macro fires, in order, from a single button tap.
///
/// A macro is how one bar button can do more than insert a literal command: it
/// chains text snippets and modified special keys so a tap can, for example,
/// rotate an agent's permission mode (a single Shift+Tab) or run a short
/// sequence. Each step resolves to bytes through ``output``, and
/// ``CustomToolbarAction/output`` concatenates them in order into one write —
/// there are deliberately no inter-step delays.
///
/// The two cases mirror the standalone ``ToolbarActionPayload`` kinds so a step
/// is either a literal ``text(_:)`` snippet or a single ``keyCombo(modifiers:key:)``.
public enum ToolbarMacroStep: Codable, Equatable, Sendable {
    /// Insert literal text.
    ///
    /// Newlines are normalized to carriage returns at send time (terminals
    /// expect `\r` for Return), matching ``ToolbarActionPayload/text(_:)``.
    /// - Parameter value: The literal text this step contributes to the macro.
    case text(String)

    /// Send a special key with the given modifiers, encoded by
    /// ``TerminalKeyEncoder``. Only combinations the encoder defines produce
    /// output; others resolve to `nil` and contribute nothing to the macro.
    /// - Parameters:
    ///   - modifiers: The modifier keys to apply when encoding `key`.
    ///   - key: The terminal special key to encode.
    case keyCombo(modifiers: TerminalKeyModifier, key: TerminalSpecialKey)

    /// The bytes this step contributes to its macro, or `nil` when it resolves to
    /// nothing (empty text, or a key combo the encoder cannot encode).
    public var output: Data? {
        resolvedOutput
    }
}

private extension ToolbarMacroStep {
    var resolvedOutput: Data? {
        switch self {
        case let .text(value):
            let normalized = value.replacingOccurrences(of: "\n", with: "\r")
            guard !normalized.isEmpty else { return nil }
            return Data(normalized.utf8)
        case let .keyCombo(modifiers, key):
            return TerminalKeyEncoder.encode(specialKey: key, modifiers: modifiers)
        }
    }
}
