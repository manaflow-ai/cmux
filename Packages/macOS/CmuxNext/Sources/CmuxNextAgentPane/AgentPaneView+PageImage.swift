public import AppKit

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again).
    public func pageImage() async -> NSImage? {
        let color = performWithTheme { AgentPaneTheme.underPageColor(themeTokens, surface: surfaceKind) }
        return await snapshotPage().map { PageImageBackground.fill($0, color) }
    }
}
