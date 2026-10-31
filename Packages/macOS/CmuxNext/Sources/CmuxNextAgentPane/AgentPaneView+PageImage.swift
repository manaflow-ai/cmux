public import AppKit
import CmuxNextDesign

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again, and so does a released page built again,
    /// `AgentPageHibernation`); nil when no picture can stand in for it
    /// (``PageImageBackground/cover(_:color:keepsClearAreas:)``).
    public func pageImage() async -> NSImage? {
        // Read before and after: the page can move to or from Chromium while its picture is taken.
        guard snapshotKeepsClearAreas || PageImageBackground.isOpaque(underPageColor) else { return nil }
        let image = await snapshotPage()
        return PageImageBackground.cover(image, color: underPageColor, keepsClearAreas: snapshotKeepsClearAreas)
    }

    /// The color the pane shows under the page, the one a saved picture is flattened over.
    private var underPageColor: ThemeRGB { AgentPaneTheme.underPageColor(themeTokens, surface: surfaceKind) }
}
