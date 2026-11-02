import AppKit
import CmuxNextDesign

/// `WindowSurfacePainting`: the window's own background, opacity and blur. The
/// root view owns them because the backdrop is one sheet behind every pane, so
/// only the view that spans the window can paint it.
extension WindowRootView {
    /// The backdrop this view's theme and the Reduce Transparency setting
    /// describe.
    var backdrop: WindowBackdrop {
        WindowBackdrop(themeTokens, reduceTransparency: reduceTransparency(), art: themeScope.backdropArt,
                       selection: themeScope.backdropSelection, tuning: themeScope.appearanceTuning,
                       tintOpacity: themeScope.backdropTintOpacity)
    }

    /// An opaque window paints the solid background on this layer. Over a
    /// material the layer stays clear and the backdrop view's tint is the
    /// one sheet; a frosted window's blur is the window's CGS radius
    /// (`applyBackdrop(to:)`).
    func paintBackground() {
        let backdrop = self.backdrop
        performWithTheme { paintBackdropSheet(backdrop, surface: Palette.surfaceBackground, backdropView: backdropView) }
    }

    /// `NSWindow.install(kind:content:scope:activeLook:)`: the backdrop before the
    /// content view goes in.
    func paintWindowSurface(of window: NSWindow) {
        applyBackdrop(to: window)
    }

    /// Sets `window`'s opacity, background and blur radius for this view's
    /// theme.
    /// Values that already match are not written again, so a repeat call
    /// (an appearance change while the window installs this view) never
    /// touches the theme frame.
    func applyBackdrop(to window: NSWindow) {
        window.applyBackdrop(backdrop, surface: performWithTheme { Palette.surfaceBackground }, applyBlur: applyWindowBlur)
    }
}
