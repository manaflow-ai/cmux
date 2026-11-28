import CmuxNextDesign
import QuartzCore

/// The tab's status badge in a status icon set (cx-kxa2): with a candidate
/// set chosen (`StatusIconSet`, Debug Settings `status.iconSet`), needs
/// input, done and failed draw the set's mark (with the OSC 7501 blocked
/// kind) at the icon's corner in place of the colored dot. The default set
/// keeps the dot, so nothing changes until a set is picked. The unread dot
/// is not a status and stays a dot.
extension TabCell {
    /// The state the badge stands for; nil without a status.
    var statusBadgeState: StatusIndicatorState? {
        switch item.status {
        case .needsInput: .waiting(kind: item.blockedKind)
        case .success: .success
        case .failure: .error
        case .none: nil
        }
    }

    /// The set's mark for the badge, or nil where the dot stays.
    func statusBadgePlan(config: StatusIndicatorConfig) -> StatusIndicatorPlan? {
        guard config.iconSet != .current, let state = statusBadgeState else { return nil }
        let plan = StatusIndicatorPlan.make(state, style: config.settings.style, animates: false, set: config.iconSet)
        return plan.glyph == .none ? nil : plan
    }

    /// Creates, updates or removes the badge mark for the item and config.
    /// A cell with a status follows the shared config, so a set switch
    /// restyles it live.
    func updateStatusGlyph() {
        if item.status != .none { StatusIndicatorAppearance.shared.register(self) }
        let config = StatusIndicatorAppearance.shared.config
        if let plan = statusBadgePlan(config: config) {
            let glyph = statusGlyphLayer ?? {
                let glyph = StatusIndicatorLayer()
                glyph.hostIsFlipped = true // the strip's tab layers live in a FlippedView
                glyph.contentsScale = scale
                themeScope.perform { glyph.colors = .current(loading: config.settings.color) }
                layer.insertSublayer(glyph.layer, below: titleLayer)
                statusGlyphLayer = glyph
                return glyph
            }()
            glyph.apply(plan, config: config)
        } else if let statusGlyphLayer {
            statusGlyphLayer.layer.removeFromSuperlayer()
            self.statusGlyphLayer = nil
        }
        layoutLayers()
    }

    /// Places the badge mark at the icon's top trailing corner, where the dot
    /// sits; true when it draws (the dot is then skipped).
    func layoutStatusGlyph(iconFrame: CGRect, visible: Bool) -> Bool {
        guard let statusGlyphLayer else { return false }
        statusGlyphLayer.contentsScale = scale
        statusGlyphLayer.layer.opacity = visible ? 1 : 0
        let side = pixel(iconFrame.width * 0.62)
        statusGlyphLayer.frame = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.minY - Metrics.space1),
                                        width: side, height: side)
        return visible
    }
}
