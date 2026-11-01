public import CoreGraphics

/// The one Liquid Glass look for floating chrome that carries text: toasts, dialogs and prompts,
/// and the sidebar's bottom-left cards (tips, Update Ready). Neutral gray glass with a soft
/// top-lit rim and continuous corners, like Rex and Apple's own toasts (user, 2026-10-20). Share
/// it, never fork it: a new glass surface picks one of the roles (``SurfaceRole``,
/// schemas/surface-roles/surface-roles.json) or adds one there.
///
/// The material itself (Liquid Glass, vibrancy before macOS 26, opaque under Reduce Transparency)
/// stays `OverlayMaterial`'s decision; this style only sets the tint, rim, radius and shadow.
///
/// Motion is not here: it lives in `MotionTunables` only. Popups open at once and close on
/// `popoverClose` to `Motion.popupCloseScale`; toasts rise on
/// `appear` and fade with `fadeIn`/`fadeOut`. Every one of them fades the card's layer, never the
/// window's `alphaValue` (a glass card ignores window alpha), and the rim fades with the card
/// because it sits inside it.
///
/// ```swift
/// let look = FloatingGlassStyle.toast.look(isDark: tokens.isDark)
/// glass.tintColor = look.veil.nsColor
/// ```
public nonisolated struct FloatingGlassStyle: Sendable, Equatable {
    /// The continuous corner radius.
    public var cornerRadius: CGFloat
    /// The veil's opacity over the glass on a dark appearance.
    public var darkVeilAlpha: Double
    /// The veil's opacity over the glass on a light appearance.
    public var lightVeilAlpha: Double
    /// The rim's top and bottom opacity on a dark appearance (white light from above).
    public var darkRim: (top: Double, bottom: Double)
    /// The rim's top and bottom opacity on a light appearance.
    public var lightRim: (top: Double, bottom: Double)
    /// Whether it casts the popups' soft shadow (floating panels); sidebar cards do not.
    public var castsShadow: Bool

    /// - Parameters:
    ///   - cornerRadius: The continuous corner radius.
    ///   - darkVeilAlpha: Veil opacity on dark.
    ///   - lightVeilAlpha: Veil opacity on light.
    ///   - darkRim: Rim top/bottom opacity on dark.
    ///   - lightRim: Rim top/bottom opacity on light.
    ///   - castsShadow: Whether it casts a shadow.
    public init(cornerRadius: CGFloat, darkVeilAlpha: Double, lightVeilAlpha: Double,
                darkRim: (top: Double, bottom: Double), lightRim: (top: Double, bottom: Double), castsShadow: Bool) {
        self.cornerRadius = cornerRadius
        self.darkVeilAlpha = darkVeilAlpha
        self.lightVeilAlpha = lightVeilAlpha
        self.darkRim = darkRim
        self.lightRim = lightRim
        self.castsShadow = castsShadow
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cornerRadius == rhs.cornerRadius && lhs.darkVeilAlpha == rhs.darkVeilAlpha
            && lhs.lightVeilAlpha == rhs.lightVeilAlpha && lhs.darkRim == rhs.darkRim
            && lhs.lightRim == rhs.lightRim && lhs.castsShadow == rhs.castsShadow
    }

    // The roles' looks (`toast`, `dialog`, `card`) are in SurfaceRole.swift, which follows
    // schemas/surface-roles/surface-roles.json (scripts/cmux-next/check-surface-roles.py).

    /// The agent cursor's name tag and keystroke caption ("Chief · workspace"): a 22 pt capsule in
    /// the toast's veil and rim, with a shadow, over the page the cursor floats on.
    public static let agentTag = FloatingGlassStyle(cornerRadius: 11, darkVeilAlpha: toast.darkVeilAlpha,
                                                    lightVeilAlpha: toast.lightVeilAlpha, darkRim: toast.darkRim,
                                                    lightRim: toast.lightRim, castsShadow: true)

    /// The colors for one appearance.
    public func look(isDark: Bool) -> FloatingGlassLook {
        if isDark {
            return FloatingGlassLook(veil: .init(white: 0.11, alpha: darkVeilAlpha),
                                     rimTop: .init(white: 1, alpha: darkRim.top),
                                     rimBottom: .init(white: 1, alpha: darkRim.bottom))
        }
        return FloatingGlassLook(veil: .init(white: 0.99, alpha: lightVeilAlpha),
                                 rimTop: .init(white: 1, alpha: lightRim.top),
                                 rimBottom: .init(white: 0, alpha: lightRim.bottom))
    }
}
