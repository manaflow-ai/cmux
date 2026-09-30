import AppKit
import CmuxNextDesign

/// The page area of a Chromium tab shows the Ghostty theme background
/// (`Palette.pageBackground`): before its first paint and under every
/// document without a background of its own (user decision 2026-09-30).
/// Chromium takes it from `CefSettings`/`CefBrowserSettings.background_color`
/// and, with fork API 12, paints it in Chrome's contents view too (before,
/// Chrome painted its New Tab page color, #292929, there). WebKit tabs show
/// it until their first real page, then WebKit's default.
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
    /// keeps the theme color for every document without a background.
    static func startsWithTheme(openedByPage: Bool) -> Bool { !openedByPage }

    /// `Palette.pageBackground` as opaque 0xAARRGGBB, the form
    /// `CefBrowserSettings.background_color` takes.
    @MainActor static var themeARGB: UInt32 {
        let color = Palette.pageBackground.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }
}
