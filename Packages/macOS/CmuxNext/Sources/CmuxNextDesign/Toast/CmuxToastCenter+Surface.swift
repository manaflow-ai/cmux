public import AppKit

extension Glass {
    /// The glass `center`'s toasts draw on now, for a toast-shaped card the center does not draw (the Import
    /// from Chrome card over a page): its style's look and its tuning's glass, as ``CmuxToastView`` builds its
    /// own (``CmuxToastView/makeSurface(look:tuning:cornerRadius:reduceTransparency:)``), so a Debug Settings
    /// toast-glass pick or a Solid style reaches both. Leo 2026-11-24: "oh yeah the import from chrome
    /// popup/toast is there too...with yet another kind of \"glass\"".
    @MainActor
    public static func makeSurface(toastOf center: CmuxToastCenter, cornerRadius: CGFloat,
                                   reduceTransparency: ReduceTransparency = .shared) -> OverlaySurfaceView {
        let look = center.style.look
        // A Solid style draws on the opaque surface, as CmuxToastView does.
        return CmuxToastView.makeSurface(look: look, tuning: center.tuning, cornerRadius: cornerRadius,
                                         reduceTransparency: look.solid ? .alwaysOpaque : reduceTransparency) // glass-opaque-allow: the Solid style is a look the person picks in the Toast Playground on purpose
    }
}
