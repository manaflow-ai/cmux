// SPDX-License-Identifier: MIT

/// Underline style for a ``Cell``. Optional ``Cell/underlineColor``
/// carries the SGR 58 color; absent ``Cell/underlineKind`` means no
/// underline (D25). Replaces the boolean `.underline` attribute from
/// pre-D25 drafts.
public enum UnderlineKind: String, Sendable, Codable, Hashable {
    /// Standard single underline (SGR 4).
    case single
    /// Double underline (SGR 21).
    case double
    /// Curly / wavy underline (SGR 4:3).
    case curly
    /// Dotted underline (SGR 4:4).
    case dotted
    /// Dashed underline (SGR 4:5).
    case dashed
}
