public import AppKit
public import CmuxNextDesign

extension AgentPaneView {
    /// An image of the page as shown (the next launch draws it until this
    /// page paints again, and so does a released page built again,
    /// `AgentPageHibernation`); nil when no picture can stand in for it
    /// (``PageImageBackground/cover(_:color:pageIsOpaque:keepsClearAreas:)``).
    public func pageImage() async -> NSImage? {
        // Read before and after: the page can move to or from Chromium while its picture is taken.
        guard snapshotKeepsClearAreas || Self.pageIsOpaque(surfaceKind, in: self) else { return nil }
        let image = await snapshotPage()
        let under = performWithTheme { AgentPaneTheme.underPageColor(themeTokens, surface: surfaceKind) }
        return PageImageBackground.cover(image, color: under, pageIsOpaque: Self.pageIsOpaque(surfaceKind, in: self),
                                         keepsClearAreas: snapshotKeepsClearAreas)
    }

    /// Whether a saved picture of a page (`AgentPaneLaunchImages`) may stand in for it under the
    /// pane: one that keeps clear pixels always, one with no alpha only when the page paints an
    /// opaque background. The draw side of ``pageImage()``'s rule, so a picture an older version saved
    /// (a Chromium JPEG of a see-through page, black where the page is clear) is never drawn by the
    /// first launch after an update.
    ///
    /// - Parameters:
    ///   - image: The saved picture.
    ///   - view: The page's view; nil when it is not made yet (a launch that defers the tab), and
    ///     the picture then covers only when every agent page would paint opaque there.
    ///   - scope: The view whose theme scope the page shows in (its pane): a workspace's own
    ///     picture or glass makes its pages clear.
    public static func savedPictureCovers(_ image: NSImage, page view: AgentPaneView?, in scope: NSView) -> Bool {
        let surfaces: [SurfaceKind] = view.map { [$0.surfaceKind] } ?? [.agentPane, .newTabPage]
        return PageImageBackground.covers(image, pageIsOpaque: surfaces.allSatisfy { pageIsOpaque($0, in: scope) })
    }

    /// Whether the page of `surface` paints an opaque background of its own in `scope`'s theme
    /// scope (`performWithTheme`).
    private static func pageIsOpaque(_ surface: SurfaceKind, in scope: NSView) -> Bool {
        scope.performWithTheme { PageImageBackground.isOpaque(AgentPaneTheme.pageBackground(scope.themeTokens, surface: surface)) }
    }
}
