public import AppKit
public import CmuxNextDesign
import Foundation

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

    /// The defaults key that turns on ``launchPicture()``'s see-through Chromium picture (off by default).
    public nonisolated static let seeThroughLaunchPictureKey = "cmux.agentPane.seeThroughLaunchPicture"

    /// The picture the next launch draws for this chat before its page paints (`AgentPaneLaunchImages`).
    ///
    /// Same as ``pageImage()``, except for a Chromium page that is clear over its window (a glass, frosted or
    /// see-through window, or a background image, the common NEXT window): ``pageImage()`` has none there (its
    /// JPEG has no alpha, so the clear pixels come out black), so no launch picture was ever saved for such a chat
    /// and a relaunch showed the loading cover, an empty transcript with a spinner, until the page and its live
    /// session answered (Leo, 2026-11-27: "stop putting the opaque thing from the start ... just all settings all
    /// layout all as soon as it comes"). With the flag on, that chat's picture is the page's PNG that keeps its
    /// clear areas (``PageWebView/clearAreaSnapshot()``), which ``AgentPaneLaunchImages/takeCovering(_:newTab:size:appearance:in:)``
    /// already accepts because it has alpha. The PNG costs the main thread more than the JPEG, so a launch picture
    /// is taken at most as often as ``AgentLaunchPictures`` saves (a page's first paint plus its settle, one per
    /// cooldown, and the quit).
    public func launchPicture(flagged: Bool = UserDefaults.standard.bool(forKey: AgentPaneView.seeThroughLaunchPictureKey)) async -> NSImage? {
        if snapshotKeepsClearAreas || Self.pageIsOpaque(surfaceKind, in: self) { return await pageImage() }
        guard flagged, let page else { return nil }
        guard let image = await page.clearAreaSnapshot(), !page.snapshotKeepsClearAreas else { return nil }
        let under = performWithTheme { AgentPaneTheme.underPageColor(themeTokens, surface: surfaceKind) }
        return PageImageBackground.cover(image, color: under, pageIsOpaque: false, keepsClearAreas: true)
    }

    /// A small picture of the page for a hover card (#51768), at most `maxPixelWidth` pixels wide: the page's
    /// clear-area-keeping picture (``PageWebView/picture(maxPixelWidth:)``, a PNG in Chromium) laid over the chat's own
    /// ground, the color the pane shows under its page. ``pageImage()`` is a JPEG in Chromium: the chat page is clear
    /// over that ground, so its picture came out flat white (capture of 2026-11-23); nil when there is none.
    public func cardPicture(maxPixelWidth: CGFloat) async -> CGImage? {
        let shot: CGImage?
        if let page { shot = await page.picture(maxPixelWidth: maxPixelWidth) } else {
            shot = await pageSnapshot()?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let shot else { return nil }
        let ground = performWithTheme { AgentPaneTheme.pageBackground(themeTokens, surface: surfaceKind, backgrounds: themeScope.surfaceBackgrounds) }
        return PageImageBackground.flattened(shot, over: ground)
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
