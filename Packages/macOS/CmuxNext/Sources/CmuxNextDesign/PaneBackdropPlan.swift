public import CmuxNextDesignTokens
/// What one pane draws for its background, from one pure resolver
/// (plans/cmux-next/pane-backgrounds-DESIGN.md): its own copy of the art, a plain cover over the
/// window's art, and a marker tint. ``none`` (the common case) means the pane draws nothing and
/// needs no view at all.
public nonisolated struct PaneBackdropPlan: Equatable, Sendable {
    /// The art backdrop the pane draws (art plus its legible tint, never a glass view); nil draws no art.
    public var art: WindowBackdrop?
    /// The pane hides the window's art under its plain theme background (its own `none` pick).
    public var cover = false
    /// The marker color washed over the pane.
    public var tint: PaneTint?
    /// The wash's opacity.
    public var tintAlpha: Double = Self.markerTintAlpha

    /// How strongly a marker tint washes over its pane: visible at a glance, text still at contrast.
    public static let markerTintAlpha = 0.12
    /// Nothing to draw.
    public static let none = PaneBackdropPlan()

    /// Whether the pane needs its backdrop view at all.
    public var needsView: Bool { art != nil || cover || tint != nil }

    /// The plan for one pane.
    ///
    /// - Parameter mode: `appearance.paneBackgrounds`.
    /// - Parameter own: The pane's own pick (`inherit` without one).
    /// - Parameter tint: The pane's marker color, if any.
    /// - Parameter backdrop: The backdrop of the pane's scope (its own pick, else inherited), with
    ///   the user's Reduce Transparency already applied.
    /// - Parameter inheritedHasArt: Whether the window behind the pane shows art.
    /// - Returns: What the pane draws.
    public static func resolve(mode: PaneBackgroundMode, own: BackdropPin, tint: PaneTint?, backdrop: WindowBackdrop,
                               inheritedHasArt: Bool) -> PaneBackdropPlan {
        var plan = PaneBackdropPlan(tint: tint)
        let ownsPick = own != .inherit
        if backdrop.selection != nil, !backdrop.isOpaque, mode == .perPane || ownsPick {
            var art = backdrop
            // One art layer and one tint per pane; the window keeps the one glass view.
            art.material = .translucent
            plan.art = art
        } else if own == .none || backdrop.isOpaque, inheritedHasArt {
            // Its own None, or its own Opacity at 100% (an opaque scope): the pane hides the
            // window's art under its plain background instead of drawing nothing over it.
            plan.cover = true
        }
        return plan
    }
}
