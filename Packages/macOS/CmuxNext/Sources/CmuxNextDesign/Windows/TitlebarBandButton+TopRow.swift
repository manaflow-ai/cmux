import AppKit
import CmuxNextIcons

extension TitlebarBandButton {
    /// Sizes the top-left band's three glyphs to one height (`TopRowSpacing.glyphExtent`): the toggle draws smaller,
    /// the arrows larger. Back and Forward draw the browser's own arrows (Chrome's), so workspace history and a page's
    /// history read as one control (Lawrence 2026-11-11: "The one that looks like Chrome, so it's the browser one").
    @MainActor
    public static func styleTopRow(toggle: TitlebarBandButton, back: TitlebarBandButton, forward: TitlebarBandButton) {
        toggle.symbolPointSize = { TopRowSpacing.toggleGlyphPointSize }
        for (button, icon) in [(back, IconName.browserToolbarBack), (forward, .browserToolbarForward)] {
            button.symbolPointSize = { TopRowSpacing.arrowIconSize }
            button.customImage = { _, size in NSImage.icon(icon, size: size) }
        }
    }
}
