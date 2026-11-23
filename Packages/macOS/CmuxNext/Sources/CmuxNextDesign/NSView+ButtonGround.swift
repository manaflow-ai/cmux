import AppKit
import CmuxNextDesignTokens

extension NSView {
    /// The overlay surface (a dialog's card, a menu or a popover) this view draws on, if any.
    var enclosingOverlaySurface: OverlaySurfaceView? {
        var view = superview
        while let current = view {
            if let surface = current as? OverlaySurfaceView { return surface }
            view = current.superview
        }
        return nil
    }

    /// What a button at this place in the view tree sits on, as ``CmuxDialogButtonLook`` takes it (`card:`):
    /// an overlay's opaque popup surface (Reduce Transparency) exactly, a menu or popover's glass over any page,
    /// a dialog card under its scrim, or else the window, over the worst desktop when the window is see-through.
    /// Call it inside `performWithTheme` with that scope's tokens.
    ///
    /// On an opaque overlay the glass estimates are not under the button: fit to them as well, a Hot Dog Stand
    /// popover's gray Cancel read 2.62:1 on its red popup surface (NativeControlContrastAuditTests).
    func buttonGround(_ tokens: ThemeTokens) -> [ThemeRGB] {
        let lift = ChromeTunables.opaqueOverlayLift.value
        guard let surface = enclosingOverlaySurface, !surface.drawsNoMaterial else {
            return CmuxDialogButtonLook.windowSurfaces(tokens)
        }
        if surface.material == .opaque {
            // glass-opaque-allow: a contrast reference only (the surface the overlay paints under Reduce Transparency)
            let popup = tokens.opaqueOverlayFill(lift: lift)
            return [popup, popup, popup]
        }
        return surface.tintLevel == .menu
            ? CmuxDialogButtonLook.menuCardSurfaces(tokens, lift: lift)
            : CmuxDialogButtonLook.cardSurfaces(tokens, lift: lift)
    }

    /// The theme ink at `ink`, moved toward its pole until it reads at `minimum` on every ground of the glass this view
    /// sits on (``buttonGround(_:)``: a menu's glass over the theme's window, a white and a black page), or nil off
    /// glass, where the theme's ink is fit to the page already. An icon button's secondary glyph on a popover read
    /// 1.71:1 over a black page (Rose Pine Dawn, NativeControlContrastAuditTests). Call it inside `performWithTheme`.
    func glassInk(_ ink: KeyPath<ThemeTokens, ThemeRGB>, minimum: Double) -> NSColor? {
        guard let surface = enclosingOverlaySurface, !surface.drawsNoMaterial, surface.material != .opaque else { return nil }
        let tokens = ThemeContext.active ?? ThemeScope.app.tokens
        let ground = buttonGround(tokens)
        return CmuxDialogButtonLook.readable(tokens[keyPath: ink].composited(over: ground[0]), over: ground, minimum: minimum).nsColor
    }
}
