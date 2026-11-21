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
    /// a menu or popover's glass over any page, a dialog card under its scrim, or else the window, over the
    /// worst desktop when the window is see-through. Call it inside `performWithTheme` with that scope's tokens.
    func buttonGround(_ tokens: ThemeTokens) -> [ThemeRGB] {
        let lift = ChromeTunables.opaqueOverlayLift.value
        return switch enclosingOverlaySurface?.tintLevel {
        case nil: CmuxDialogButtonLook.windowSurfaces(tokens)
        case .menu?: CmuxDialogButtonLook.menuCardSurfaces(tokens, lift: lift)
        default: CmuxDialogButtonLook.cardSurfaces(tokens, lift: lift)
        }
    }
}
