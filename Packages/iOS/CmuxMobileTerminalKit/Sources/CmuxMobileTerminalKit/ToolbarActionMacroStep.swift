public import Foundation

/// One executable step inside a custom terminal toolbar macro.
///
/// Steps are intentionally the same primitives as a one-shot custom action:
/// literal terminal text, or a modified special key encoded by
/// ``TerminalKeyEncoder``. ``ToolbarActionPayload/macro(_:)`` sends each step in
/// order and refuses to send a partial macro if any step cannot be encoded.
public enum ToolbarActionMacroStep: Codable, Equatable, Sendable {
    /// Insert literal text. Newlines are normalized to carriage returns at send
    /// time, matching terminal Return handling.
    case text(String)

    /// Send a special key with the given modifiers.
    case keyCombo(modifiers: TerminalKeyModifier, key: TerminalSpecialKey)

    /// The bytes sent for this step, or `nil` when the step is empty or has no
    /// defined terminal encoding.
    public var output: Data? {
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
