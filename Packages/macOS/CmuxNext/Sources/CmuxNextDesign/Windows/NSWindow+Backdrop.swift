public import AppKit
public import CmuxNextDesignTokens

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
        // A window-server call: only when the radius (or the window number it was set on) moved.
        let blur = AppliedBlur(windowNumber: windowNumber, radius: backdrop.windowBlurRadius)
        guard appliedBlur != blur else { return }
        applyBlur(self, blur.radius)
        // Before the window has a number the call sets nothing: try again next time.
        appliedBlur = windowNumber > 0 ? blur : nil
    }

    private struct AppliedBlur: Equatable {
        var windowNumber: Int
        var radius: Int
    }

    private static let appliedBlurs = ObjectAssociation<[Int]>()

    /// The blur radius last set on this window and the window number it was set on.
    private var appliedBlur: AppliedBlur? {
        get {
            Self.appliedBlurs.value(on: self).flatMap {
                $0.count == 2 ? AppliedBlur(windowNumber: $0[0], radius: $0[1]) : nil
            }
        }
        set {
            Self.appliedBlurs.set(newValue.map { [$0.windowNumber, $0.radius] }, on: self)
        }
    }
}

extension NSView {
    /// The view half of the one backdrop: an opaque window's sheet paints
    /// the solid token on this view's layer; over a material the layer
    /// stays clear and `backdropView` shows the material and the tint.
    /// Every surface above stays clear.
    public func paintBackdropSheet(_ backdrop: WindowBackdrop, surface: NSColor, backdropView: WindowMaterialView) {
        let fill = backdrop.isOpaque ? surface.withAlphaComponent(1).cgColor : nil
        // A workspace switch or theme change blends the sheet from the color on screen
        // (appearance.colorTransition); a change to or from a material applies at once.
        if let layer, layer.backgroundColor != fill {
            if fill != nil, layer.backgroundColor != nil, window?.isVisible == true {
                ColorTransition.current.animate(layer, to: fill)
            } else {
                layer.removeAnimation(forKey: ColorTransition.layerKey)
                layer.backgroundColor = fill
            }
        }
        backdropView.apply(backdrop, tint: surface)
    }
}
