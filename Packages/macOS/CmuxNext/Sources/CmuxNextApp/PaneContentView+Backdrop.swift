import AppKit
import CmuxNextDesign

/// The pane's own background (plans/cmux-next/pane-backgrounds-DESIGN.md): its own copy of the
/// art (`appearance.paneBackgrounds` perPane, or the pane's own pick), a plain cover over the
/// window's art (its own `none`), and a marker tint over the pane. What it draws comes from
/// `PaneBackdropPlan`; in the common case (one shared background, no pick, no tint) the pane
/// makes no view at all.
extension PaneContentView {
    /// Pins the pane's own background on its scope (what its terminals and pages see) and its
    /// marker tint, then repaints.
    func setPaneBackground(pin: BackdropPin, tint: PaneTint?, glass: Double?) {
        let state = backdropState
        guard pin != state.pin || tint != state.tint || glass != state.glass else { return }
        state.pin = pin
        state.tint = tint
        state.glass = glass
        paneScope.pinBackdrop(pin)
        paneScope.pinBackdropTint(glass)
        paintPaneBackdrop()
    }

    /// What this pane draws now.
    var paneBackdropPlan: PaneBackdropPlan {
        let scope = paneScope
        let backdrop = WindowBackdrop(scope.tokens, reduceTransparency: ReduceTransparency.shared.isEnabled, art: scope.backdropArt,
                                      selection: scope.backdropSelection, tuning: scope.appearanceTuning,
                                      tintOpacity: scope.backdropTintOpacity)
        return PaneBackdropPlan.resolve(mode: DesignSettings.shared.paneBackgrounds, own: backdropState.pin, tint: backdropState.tint,
                                        backdrop: backdrop, inheritedHasArt: scope.parent?.backdropSelection != nil)
    }

    /// Applies ``paneBackdropPlan``: the art view under everything, the tint wash over it.
    func paintPaneBackdrop() {
        // The common case (one shared background, nothing of its own, nothing drawn yet) costs nothing.
        let state = backdropState
        if DesignSettings.shared.paneBackgrounds == .shared, !state.hasOwnValues, !state.hasViews { return }
        let plan = paneBackdropPlan
        let surface = performWithTheme { Palette.surfaceBackground }
        if let art = plan.art {
            let view = backdropState.artView ?? makeArtView()
            view.isHidden = false
            view.apply(art, tint: surface)
        } else {
            backdropState.artView?.isHidden = true
        }
        if plan.cover {
            let cover = backdropState.coverView ?? makeCoverView()
            cover.isHidden = false
            cover.layer?.backgroundColor = surface.withAlphaComponent(1).cgColor
        } else {
            backdropState.coverView?.isHidden = true
        }
        if let tint = plan.tint {
            let view = backdropState.tintView ?? makeTintView()
            view.isHidden = false
            view.layer?.backgroundColor = CGColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: plan.tintAlpha)
        } else {
            backdropState.tintView?.isHidden = true
        }
        // A pane with its own pick decides its content's fill from its own scope (its terminals
        // already do): over its art the content stays clear.
        if backdropState.pin != .inherit {
            let paints = WindowBackdrop(paneScope.tokens, reduceTransparency: ReduceTransparency.shared.isEnabled,
                                        selection: paneScope.backdropSelection).panesPaintBackground
            contentHost.layer?.backgroundColor = paints ? surface.cgColor : nil
        }
    }

    private func makeArtView() -> WindowMaterialView {
        let view = WindowMaterialView(frame: bounds, videos: backdropVideos)
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: subviews.first)
        backdropState.artView = view
        return view
    }

    /// Under the content and over the art view: hides the window's art behind this pane.
    private func makeCoverView() -> NSView {
        let view = NSView(frame: bounds)
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: contentHost)
        backdropState.coverView = view
        return view
    }

    /// Over everything in the pane (strip included), taking no clicks.
    private func makeTintView() -> PaneTintView {
        let view = PaneTintView(frame: bounds)
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .above, relativeTo: nil)
        backdropState.tintView = view
        return view
    }
}
