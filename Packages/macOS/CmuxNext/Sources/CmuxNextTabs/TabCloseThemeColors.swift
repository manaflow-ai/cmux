import AppKit
import CmuxNextDesign
import QuartzCore

/// A theme's close button colors on one tab (`appearance.tabClose.*`, `ThemeFlourishes.TabClose`):
/// the x rests in `from` and, under the pointer or held, takes the hover color, which also tints the
/// hover fill; an end left unset is today's (the title color, the text-ink fill). The x blends
/// between them in the theme's color space at the tab bar's hover pace (`Motion.tabs`: at once
/// when motion is off). Only a tab whose strip has the colors set comes here
/// (`TabCell.applyCloseColors`); without them the tab keeps its own path.
struct TabCloseThemeColors {
    let cell: TabCell

    /// Paints the close button's x and hover fill.
    func apply() {
        guard let background = cell.closeBackgroundLayer, let glyph = cell.closeGlyphLayer else { return }
        let colors = cell.metrics.closeColors
        cell.themeScope.perform {
            let title = cell.isSelected ? Palette.textPrimary : Palette.textSecondary
            let hot = cell.isCloseHovered || cell.isClosePressed
            let hover = colors.to(dark: cell.themeScope.tokens.isDark)?.nsColor
            let stroke = hot ? hover ?? title : colors.from?.nsColor ?? title
            let duration = Motion.tabs.duration(hot ? .hover : .hoverOut)
            ColorTransition(enabled: duration > 0, duration: duration, space: colors.space).animateStroke(glyph, to: stroke.cgColor)
            // The `disc` treatment draws the fill while the x stands in for the status, as the tab's own path does.
            let disc = cell.metrics.hoverCloseSwap == .disc && cell.visibility.closeReplacesStatus
            let percent = BrowserChromeTuning.value(.closeHoverOpacity) - (cell.isClosePressed ? 2 : 0)
            background.backgroundColor = hot || disc
                ? (hover ?? Palette.textPrimary).withAlphaComponent(max(0, percent) / 100).cgColor : nil
        }
    }
}
