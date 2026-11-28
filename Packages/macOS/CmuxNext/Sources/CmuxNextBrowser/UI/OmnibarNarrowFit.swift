import CoreGraphics

/// What the omnibar gives up as it narrows, so the URL text keeps room and never runs under its icons (QA
/// sweep-06675353 D7: at a 203 pt pane the text was a sliver under the star). As Chrome's location bar does, the
/// page-info chip's label ("Not secure", "File") folds into its icon first; then the trailing badges (the bookmark
/// star, the profile, machine and focus mode badges) hide. Each step is taken only while the text would be narrower
/// than ``minimumTextWidth``; the field's own text then truncates in what is left.
nonisolated struct OmnibarNarrowFit: Equatable, Sendable {
    var showsChipLabel: Bool
    var showsBadges: Bool

    /// The text width kept before the next thing gives way: about five characters of the omnibar's font.
    static let minimumTextWidth: CGFloat = 40

    /// The fit at `barWidth`. `chipLabeled` is the chip's width with its label (`chipIcon` when it has none); `badges`
    /// the shown badges' width (0: none). With badges the field ends `fieldTrailingGap` before them and they sit
    /// `badgesInset` from the bar's end; without, the field ends `trailingPadding` from it.
    static func resolve(barWidth: CGFloat, chipLeading: CGFloat, chipIcon: CGFloat, chipLabeled: CGFloat, textLeading: CGFloat,
                        badges: CGFloat, badgesInset: CGFloat, fieldTrailingGap: CGFloat, trailingPadding: CGFloat,
                        minimumText: CGFloat = minimumTextWidth) -> OmnibarNarrowFit {
        func text(label: Bool, badgesShown: Bool) -> CGFloat {
            let trailing = badgesShown && badges > 0 ? fieldTrailingGap + badges + badgesInset : trailingPadding
            return barWidth - chipLeading - (label ? chipLabeled : chipIcon) - textLeading - trailing
        }
        let hasLabel = chipLabeled > chipIcon
        if !hasLabel || text(label: true, badgesShown: true) >= minimumText {
            if hasLabel || badges <= 0 || text(label: false, badgesShown: true) >= minimumText {
                return OmnibarNarrowFit(showsChipLabel: true, showsBadges: true)
            }
            return OmnibarNarrowFit(showsChipLabel: true, showsBadges: false)
        }
        if badges <= 0 || text(label: false, badgesShown: true) >= minimumText {
            return OmnibarNarrowFit(showsChipLabel: false, showsBadges: true)
        }
        return OmnibarNarrowFit(showsChipLabel: false, showsBadges: false)
    }
}
