// SPDX-License-Identifier: MIT

/// Visual SGR-style cell attribute. The grid stores a `Set` of these
/// per cell. NOTE (D25): there is intentionally NO `.underline` case —
/// underline state lives on ``Cell/underlineKind`` (with optional
/// ``Cell/underlineColor``).
public enum CellAttribute: String, Sendable, Codable, Hashable, CaseIterable {
    /// Bold rendering (SGR 1).
    case bold
    /// Italic rendering (SGR 3).
    case italic
    /// Faint / dim rendering (SGR 2).
    case faint
    /// Blinking text (SGR 5/6).
    case blink
    /// Reverse video (SGR 7).
    case inverse
    /// Invisible / hidden text (SGR 8).
    case invisible
    /// Strikethrough (SGR 9).
    case strikethrough
}
