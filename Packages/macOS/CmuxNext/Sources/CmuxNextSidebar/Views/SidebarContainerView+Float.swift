public import AppKit
import CmuxNextDesign

// `sidebar.floatOnHover` (Lawrence 2026-11-08): the hidden sidebar floats over the content as a
// card, inset from the window edges by the main pane's gutter with corners concentric with the
// window's, on the popups' shadow. The card slides in and out on the sidebar's own width motion
// (the container widens to the user's width plus the inset), so Reduce Motion and the sidebar's
// animation switches apply as they do to show and hide. Its surface is the overlays' shared glass
// (`Glass.makeOverlayPanel`, tinted with the theme, with its own rim), solid only under Reduce
// Transparency.
extension SidebarContainerView {
    /// The float's inset from the window's top, bottom and sidebar edges: the main pane's gutter,
    /// so the card and the pane card sit the same distance from the window.
    public static var floatInset: CGFloat { Metrics.mainPaneGutter }

    /// The width the container is at or animating to: the model's, plus the inset while floating.
    var floatTargetWidth: CGFloat { model.displayWidth + (model.isFloating ? Self.floatInset : 0) }

    /// Sets the card look on or off for ``isFloatOverlay``: the panel inset and rounded, the clip
    /// unclipped so the shadow shows (the window's own edge hides the card while it slides in).
    func applyFloatLook() {
        let on = isFloatOverlay
        let inset = on ? Self.floatInset : 0
        panelTop.constant = inset
        panelBottom.constant = -inset
        panel.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = panel.layer {
            layer.cornerRadius = on ? floatCornerRadius : 0
            layer.cornerCurve = .circular
            layer.masksToBounds = on
        }
        clipLayer?.masksToBounds = !on
        floatShadowLayer.isHidden = !on
        CATransaction.commit()
        mountFloatGlass()
        floatGlass.isHidden = !on
        floatGlass.cornerRadius = on ? floatCornerRadius : 0
        applySurfaceFill()
        syncHandleVisibility()
        needsLayout = true
    }

    /// Puts the glass under the panel, edge to edge with the card, once.
    private func mountFloatGlass() {
        guard floatGlass.superview == nil, let host = panel.superview else { return }
        host.addSubview(floatGlass, positioned: .below, relativeTo: panel)
        NSLayoutConstraint.activate([
            floatGlass.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            floatGlass.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            floatGlass.topAnchor.constraint(equalTo: panel.topAnchor),
            floatGlass.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    /// The card's corner radius (set by the window: concentric with its corners across the inset).
    public var floatCornerRadius: CGFloat {
        get { floatCornerRadiusValue }
        set {
            guard floatCornerRadiusValue != newValue else { return }
            floatCornerRadiusValue = newValue
            if isFloatOverlay { applyFloatLook() }
        }
    }

    /// Shapes the shadow to the card's rect (the panel's frame in the clip).
    func layoutFloatShadow() {
        guard isFloatOverlay, let clipLayer else { return }
        let shadow = floatShadowLayer
        if shadow.superlayer !== clipLayer {
            let elevation = PopupStyle.standard.elevation
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = Float(elevation.alpha)
            shadow.shadowRadius = elevation.layerRadius
            shadow.shadowOffset = elevation.layerOffset()
            clipLayer.insertSublayer(shadow, at: 0)
        }
        let rect = panel.frame
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = min(floatCornerRadius, min(rect.width, rect.height) / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadow.frame = clipLayer.bounds
        shadow.shadowPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }
}
