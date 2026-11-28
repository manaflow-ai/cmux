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

    /// The widths a fit is resolved from, as the omnibar last measured them: the chip's label and each shown badge's
    /// `fittingSize`, an Auto Layout pass each (about 0.7 ms of every window resize step per browser pane when measured
    /// at each new width; 2026-11-27 sample of a corner drag). They change with what the chip and badges show and with
    /// the density, never with the bar's width, so a new width resolves from them and measures again only when its fit
    /// differs.
    nonisolated struct Widths: Equatable, Sendable {
        var chipLeading, chipIcon, chipLabeled, textLeading, badges, badgesInset, fieldTrailingGap, trailingPadding: CGFloat

        /// The fit at `barWidth`; before the bar has a width (its first layout) nothing folds.
        func fit(at barWidth: CGFloat) -> OmnibarNarrowFit {
            guard barWidth > 0 else { return OmnibarNarrowFit(showsChipLabel: true, showsBadges: true) }
            return OmnibarNarrowFit.resolve(barWidth: barWidth, chipLeading: chipLeading, chipIcon: chipIcon, chipLabeled: chipLabeled,
                                            textLeading: textLeading, badges: badges, badgesInset: badgesInset,
                                            fieldTrailingGap: fieldTrailingGap, trailingPadding: trailingPadding)
        }
    }
}
