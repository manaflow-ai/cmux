import AppKit
import CmuxNextDesign

/// The page area of a new or loading tab shows the Ghostty theme background
/// (`Palette.pageBackground`), never a white flash (user feedback, nxdog9).
///
/// Both engines draw the theme color until the tab's first real page
/// arrives, then return to the engine default, so a page without a
/// background of its own (plain text, unstyled HTML) keeps Chrome's and
/// Safari's white instead of dark text on a dark theme color.
nonisolated enum PageBackground {
    /// A URL whose document keeps the theme color: nothing, or the blank
    /// page of a new tab.
    static func isBlank(_ url: URL?) -> Bool {
        guard let url else { return true }
        return url.absoluteString == "about:blank" || url.absoluteString.isEmpty
    }

    /// `Palette.pageBackground` as opaque 0xAARRGGBB, the form
    /// `CefBrowserSettings.background_color` takes.
    @MainActor static var themeARGB: UInt32 {
        let color = Palette.pageBackground.usingColorSpace(.sRGB) ?? .black
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return 0xFF00_0000 | byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }
}
