public import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again, and so does a released page built again,
    /// `AgentPageHibernation`); nil when no picture can stand in for it
    /// (``PageImageBackground/cover(_:color:pageIsOpaque:keepsClearAreas:)``).
    public func pageImage() async -> NSImage? {
        // Read before and after: the page can move to or from Chromium while its picture is taken.
        guard snapshotKeepsClearAreas || pageColors.pageIsOpaque else { return nil }
        let image = await snapshotPage()
        let colors = pageColors
        return PageImageBackground.cover(image, color: colors.under, pageIsOpaque: colors.pageIsOpaque,
                                         keepsClearAreas: snapshotKeepsClearAreas)
    }

    /// The color the pane shows under the page (a saved picture is flattened over it), and whether
    /// the page paints an opaque background of its own, both in this view's scope
    /// (`performWithTheme`): a workspace's own picture or glass makes its pages clear.
    private var pageColors: (under: ThemeRGB, pageIsOpaque: Bool) {
        performWithTheme {
            let tokens = themeTokens, surface = surfaceKind
            return (AgentPaneTheme.underPageColor(tokens, surface: surface),
                    PageImageBackground.isOpaque(AgentPaneTheme.pageBackground(tokens, surface: surface)))
        }
    }
}
