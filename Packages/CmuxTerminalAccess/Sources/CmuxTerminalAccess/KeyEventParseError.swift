// SPDX-License-Identifier: MIT

/// Failure modes of ``KeyEvent/parse(_:)`` (D21). Distinct from
/// ``TerminalAccessError`` — the decoder wraps this into
/// ``TerminalAccessError/badRequest(reason:)``.
public enum KeyEventParseError: Error, Equatable {
    /// The input string was empty.
    case empty
    /// A modifier segment was not one of the recognised names.
    case unknownModifier(String)
    /// The key segment was not a known named key or a single printable
    /// character.
    case unknownKey(String)
    /// The input was structurally malformed (e.g. leading/trailing `+`,
    /// empty segments).
    case malformed(String)
}
