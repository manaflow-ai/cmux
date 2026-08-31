public import SwiftUI

/// How a filter match is emphasised inside a row label.
///
/// Matched characters get a tinted pill behind them rather than a coloured
/// foreground. Recolouring the text would put a second blue next to the
/// selection fill, which is already cmux's accent, and the two blues then
/// compete to mean different things. A background tint reads as "the search
/// found this here" without borrowing the colour that means "this row is
/// selected".
///
/// On a selected row the tint is drawn from white instead of the accent,
/// because the accent is the background there, and unmatched text steps back
/// so the match wins on contrast rather than on weight alone.
public struct SidebarFilterHighlightStyle: Sendable {
    /// The sidebar accent, used for the tint on unselected rows.
    public let accent: Color
    /// Whether the row is the selected one.
    public let isActiveRow: Bool
    /// Whether the sidebar is drawing in its dark scheme.
    public let isDark: Bool

    /// Creates a style.
    ///
    /// - Parameters:
    ///   - accent: The sidebar accent color.
    ///   - isActiveRow: Whether the row being drawn is selected.
    ///   - isDark: Whether the sidebar is in its dark scheme.
    public init(accent: Color, isActiveRow: Bool, isDark: Bool) {
        self.accent = accent
        self.isActiveRow = isActiveRow
        self.isDark = isDark
    }

    /// Background tint painted behind a matched run.
    ///
    /// The accent needs more alpha on a near-black ground than on a light one
    /// to reach the same apparent contrast, so the tint is scheme-aware rather
    /// than one constant that is right in exactly one theme.
    public var matchBackground: Color {
        if isActiveRow {
            return Color.white.opacity(0.28)
        }
        return accent.opacity(isDark ? 0.34 : 0.22)
    }

    /// Foreground for a matched run.
    public var matchForeground: Color {
        isActiveRow ? .white : .primary
    }

    /// Foreground for the rest of the label.
    ///
    /// Stepped back on a selected row so the match reads as emphasis; left
    /// alone otherwise, since the tint is already doing the work.
    public var restForeground: Color {
        isActiveRow ? Color.white.opacity(0.72) : .primary
    }

    /// Builds the attributed label for `displayText` with `ranges` emphasised.
    ///
    /// - Parameters:
    ///   - displayText: The label exactly as the row draws it.
    ///   - ranges: Match ranges from ``SidebarFilterMatch/highlightRanges(for:in:)``.
    /// - Returns: An attributed string whose plain text equals `displayText`.
    public func attributedLabel(
        displayText: String,
        ranges: [Range<Int>]
    ) -> AttributedString {
        let runs = SidebarFilterHighlightedText.runs(displayText: displayText, ranges: ranges)
        var result = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            if run.isMatch {
                piece.foregroundColor = matchForeground
                piece.backgroundColor = matchBackground
            } else {
                piece.foregroundColor = restForeground
            }
            result.append(piece)
        }
        return result
    }
}
