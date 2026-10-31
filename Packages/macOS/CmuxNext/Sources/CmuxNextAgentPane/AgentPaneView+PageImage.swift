public import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again, and so does a released page built again,
    /// `AgentPageHibernation`); nil when no picture can stand in for it
    /// (``PageImageBackground/cover(_:color:pageIsOpaque:keepsClearAreas:)``).
    public func pageImage() async -> NSImage? {
        // Read before and after: the page can move to or from Chromium while its picture is taken.
        guard snapshotKeepsClearAreas || pageColors(in: self).pageIsOpaque else { return nil }
        let image = await snapshotPage()
        let colors = pageColors(in: self)
        return PageImageBackground.cover(image, color: colors.under, pageIsOpaque: colors.pageIsOpaque,
                                         keepsClearAreas: snapshotKeepsClearAreas)
    }

    /// Whether a saved picture of this page (`AgentPaneLaunchImages`) may stand in for it under the
    /// pane: one that keeps clear pixels always, one with no alpha only over a page that paints an
    /// opaque background. The draw side of ``pageImage()``'s rule, so a picture an older version saved
    /// (a Chromium JPEG of a see-through page, black where the page is clear) is never drawn by the
    /// first launch after an update.
    ///
    /// - Parameters:
    ///   - image: The saved picture.
    ///   - scope: The view whose theme scope the page will show in (its pane): a workspace's own
    ///     picture or glass makes its pages clear.
    public func pictureCoversPage(_ image: NSImage, in scope: NSView) -> Bool {
        PageImageBackground.covers(image, pageIsOpaque: pageColors(in: scope).pageIsOpaque)
    }

    /// The color the pane shows under the page (a saved picture is flattened over it), and whether
    /// the page paints an opaque background of its own, both in `scope`'s theme scope
    /// (`performWithTheme`).
    private func pageColors(in scope: NSView) -> (under: ThemeRGB, pageIsOpaque: Bool) {
        scope.performWithTheme {
            let tokens = themeTokens, surface = surfaceKind
            return (AgentPaneTheme.underPageColor(tokens, surface: surface),
                    PageImageBackground.isOpaque(AgentPaneTheme.pageBackground(tokens, surface: surface)))
        }
    }
}
