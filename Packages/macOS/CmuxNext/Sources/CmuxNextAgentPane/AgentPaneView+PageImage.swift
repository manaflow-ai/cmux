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

    /// A small picture of the page for a hover card (#51768), at most `maxPixelWidth` pixels wide: the page's
    /// clear-area-keeping picture (``PageWebView/picture(maxPixelWidth:)``, a PNG in Chromium) laid over the chat's own
    /// ground, the color the pane shows under its page. ``pageImage()`` is a JPEG in Chromium: the chat page is clear
    /// over that ground, so its picture came out flat white (capture of 2026-11-23); nil when there is none.
    ///
    /// Where that ground is see-through (a glass window, a backdrop picture), the page is laid over what the window
    /// shows under the chat, as the window server composited it (``NSWindow/ownCapturePlan(of:)``): the card shows the
    /// chat's real background, not black (its clear pixels drawn without alpha) and not the card's own fill (Leo,
    /// 2026-11-27: "the only thing i wanted was that the thumbnail be fixed to reflect the actual bg instead of black
    /// screen"). That capture starts in this turn, while the chat still shows (a chat leaving the screen is pictured
    /// right before it hides), and runs off the main actor.
    public func cardPicture(maxPixelWidth: CGFloat) async -> CGImage? {
        let ground = performWithTheme { AgentPaneTheme.pageBackground(themeTokens, surface: surfaceKind, backgrounds: themeScope.surfaceBackgrounds) }
        let under = PageImageBackground.isOpaque(ground) ? nil : underPageCapture()
        let shot: CGImage?
        if let page { shot = await page.picture(maxPixelWidth: maxPixelWidth) } else {
            shot = await pageSnapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let shot else { return nil }
        if let under, let background = await under.value {
            return await Task.detached(priority: .userInitiated) { PageImageBackground.laid(shot, over: background) }.value
        }
        return PageImageBackground.flattened(shot, over: ground)
    }

    /// What this pane's window shows under the page, captured off the main actor (the window alone: Chromium draws
    /// the page in a child window, which it leaves out); nil when the pane is not in a window on screen.
    private func underPageCapture() -> Task<CGImage?, Never>? {
        let shown: NSView = page ?? webView
        guard let window, let plan = window.ownCapturePlan(of: shown.convert(shown.bounds, to: nil)) else { return nil }
        return Task.detached(priority: .userInitiated) { NSWindow.capture(plan) }
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
