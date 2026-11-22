public import AppKit

extension NSWindow {
    /// The window half of the one backdrop (plans/cmux-next/windows.md):
    /// opaque with the solid surface token, or non-opaque with a white
    /// background at ``WindowBackdrop/windowBackgroundAlpha`` (kept for the
    /// shadow and hit testing) and the backdrop's CGS blur radius. Values
    /// that already match are not written again: a background write after
    /// the content view is installed reorders the titlebar.
    ///
    /// - Parameter backdrop: The backdrop of the window's theme.
    /// - Parameter surface: The surface token in the window's scope.
    /// - Parameter applyBlur: Sets the behind-window blur radius (tests record it).
    public func applyBackdrop(_ backdrop: WindowBackdrop, surface: NSColor,
                              applyBlur: @MainActor (NSWindow, Int) -> Void = { $0.setBackgroundBlurRadius($1) }) {
        let color = backdrop.isOpaque ? surface.withAlphaComponent(1) : NSColor.white.withAlphaComponent(backdrop.windowBackgroundAlpha)
        if isOpaque != backdrop.isOpaque { isOpaque = backdrop.isOpaque }
        if backgroundColor != color { backgroundColor = color }
        applyBlur(self, backdrop.windowBlurRadius)
    }
}

extension NSView {
    /// The view half of the one backdrop: an opaque window's sheet paints
    /// the solid token on this view's layer; over a material the layer
    /// stays clear and `backdropView` shows the material and the tint.
    /// Every surface above stays clear.
    public func paintBackdropSheet(_ backdrop: WindowBackdrop, surface: NSColor, backdropView: WindowMaterialView) {
        let fill = backdrop.isOpaque ? surface.withAlphaComponent(1).cgColor : nil
        if layer?.backgroundColor != fill { layer?.backgroundColor = fill }
        backdropView.apply(backdrop, tint: surface)
    }
}
