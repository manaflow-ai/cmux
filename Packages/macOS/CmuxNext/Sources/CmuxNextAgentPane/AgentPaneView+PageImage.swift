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
    ///   - newTab: Whether the page is a New Tab page (its tab's record, known before its view is
    ///     made: a launch that defers the tab draws its picture first).
    ///   - scope: The view whose theme scope the page shows in (its pane): a workspace's own
    ///     picture or glass makes its pages clear.
    public static func savedPictureCovers(_ image: NSImage, newTab: Bool, in scope: NSView) -> Bool {
        PageImageBackground.covers(image, pageIsOpaque: pageIsOpaque(newTab ? .newTabPage : .agentPane, in: scope))
    }

    /// Whether the page of `surface` paints an opaque background of its own in `scope`'s theme
    /// scope (`performWithTheme`).
    private static func pageIsOpaque(_ surface: SurfaceKind, in scope: NSView) -> Bool {
        scope.performWithTheme { PageImageBackground.isOpaque(AgentPaneTheme.pageBackground(scope.themeTokens, surface: surface)) }
    }
}

extension AgentPaneLaunchImages {
    /// `key`'s last page (``take(_:size:appearance:)``) when it may stand in for the page in `scope`
    /// (``AgentPaneView/savedPictureCovers(_:newTab:in:)``): a saved picture with no alpha over a page that is clear
    /// now (an older version's Chromium JPEG of a see-through page) is black where the page is clear, so it is nil
    /// and the pane shows its loading state instead.
    public func takeCovering(_ key: String, newTab: Bool, size: NSSize, appearance: NSAppearance.Name?, in scope: NSView) -> NSImage? {
        take(key, size: size, appearance: appearance).flatMap { AgentPaneView.savedPictureCovers($0, newTab: newTab, in: scope) ? $0 : nil }
    }
}
