import QuartzCore

/// What a mark's mask was drawn for: redrawn only when the mark or the
/// pixel size changes, never per color change (the tint is the layer's
/// background color).
struct StatusMarkKey: Hashable {
    var mark: StatusMark
    var pixels: Int
}

/// A status icon set's mark (`StatusIndicatorPlan.Glyph.mark`): one tinted layer
/// masked by the mark drawn as alpha (`StatusMarkArt`), like the native and
/// braille styles, so it costs one sublayer and recolors for free. Pulse
/// and spin animate the layer itself.
extension StatusIndicatorLayer {
    func buildMark(_ mark: StatusMark, in rect: CGRect) {
        let tinted = markLayer ?? {
            let tinted = CALayer()
            tinted.actions = Self.noActions
            let mask = CALayer()
            mask.actions = Self.noActions
            mask.contentsGravity = .resizeAspect
            tinted.mask = mask
            layer.addSublayer(tinted)
            markLayer = tinted
            return tinted
        }()
        if tinted.frame != rect {
            tinted.frame = rect
            tinted.mask?.frame = tinted.bounds
        }
        tinted.mask?.contentsScale = contentsScale
        let key = StatusMarkKey(mark: mark, pixels: Int((rect.width * contentsScale).rounded()))
        if key != markKey {
            markKey = key
            tinted.mask?.contents = StatusMarkArt.mask(mark, pixels: key.pixels)
        }
    }

    func removeMark() {
        markLayer?.removeFromSuperlayer()
        markLayer = nil
        markKey = nil
    }
}
