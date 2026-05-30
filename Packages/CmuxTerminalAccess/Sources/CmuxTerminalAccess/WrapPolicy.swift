// SPDX-License-Identifier: MIT

/// How to render soft-wrapped (DECAWM) lines when emitting plain text.
/// ``join`` requires ghostty patch #1; Phase 0 rejects with
/// ``TerminalAccessError/unsupported(reason:)`` (415).
public enum WrapPolicy: String, Sendable, Codable, CaseIterable {
    /// Preserve hard newlines at every visual row boundary.
    case preserve
    /// Join soft-wrapped logical lines into single lines.
    case join
}
