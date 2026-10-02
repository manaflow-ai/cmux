import AppKit
import CmuxNextDesign

/// The page area of a tab shows the Ghostty theme background
/// (`Palette.pageBackground`) only before its first real page (a new tab,
/// loading); after it, a page without a background of its own is white
/// (the web default), popups and moved tabs included (coordinator
/// decision 2026-09-30, both engines). Chromium starts on
/// `CefBrowserSettings.background_color` and switches per tab with
/// `cmux_browser_set_background_color` (fork API 12, which also paints it
/// in Chromium's contents view, so it survives tab moves and popups).
nonisolated enum PageBackground {
    /// A URL whose document keeps the theme color in WebKit: nothing, or
    /// the page of a new tab.
    static func isBlank(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString.isEmpty || BrowserNewTabPage.isNewTabPage(url)
    }

    /// WebKit: whether a new page starts on the theme color: only a tab
    /// cmux opens (a new tab, before its first paint). A page a page opened
    /// (a popup, target=_blank) takes WebKit's default at once. Chromium
    /// does the same (`CEFTab.pastFirstRealPage`).
    static func startsWithTheme(openedByPage: Bool) -> Bool { !openedByPage }

    /// Chromium's white default, 0xAARRGGBB.
    static let engineDefaultARGB: UInt32 = 0xFFFF_FFFF

    /// The Chromium page background: the theme color until the tab's first
    /// real page, then white.
    static func chromiumARGB(pastFirstRealPage: Bool, theme: UInt32) -> UInt32 {
        pastFirstRealPage ? engineDefaultARGB : theme
    }

    /// True when a committed document is a real page (not blank, not the
    /// New Tab page).
    static func isRealPage(_ url: URL?) -> Bool { !isBlank(url) }

    /// `Palette.pageBackground` of `view`'s theme scope (its room,
    /// workspace or terminal theme) as opaque 0xAARRGGBB, the form
    /// `CefBrowserSettings.background_color` takes.
    @MainActor static func themeARGB(in view: NSView) -> UInt32 {
        argb(view.performWithTheme { Palette.pageBackground })
    }

    /// The app theme's (Ghostty config) page background: Chromium's
    /// process default for a browser before it joins a scoped view.
    @MainActor static var appThemeARGB: UInt32 {
        argb(ThemeScope.app.perform { Palette.pageBackground })
    }

    static func argb(_ color: NSColor) -> UInt32 {
        let color = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }
}
