import CmuxNextDesign
import QuartzCore

/// The tab's status badge in a status icon set (cx-kxa2): with a candidate
/// set chosen (`StatusIconSet`, Debug Settings `status.iconSet`), needs
/// input, done and failed draw the set's mark (with the OSC 7501 blocked
/// kind) where the colored dot draws (the trailing cluster, TabCell+TrailingMarks). The default set
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

    /// The set's mark for the badge, or nil where the dot stays. The static
    /// look (`StatusIndicatorConfig.isStatic`) always draws a mark: each
    /// state its own shape, never a dot told apart by color alone.
    func statusBadgePlan(config: StatusIndicatorConfig) -> StatusIndicatorPlan? {
        guard config.iconSet != .current || config.isStatic, let state = statusBadgeState else { return nil }
        let plan = StatusIndicatorPlan.make(state, style: config.settings.style, animates: false, set: config.iconSet, isStatic: config.isStatic,
                                            staticShapes: config.staticShapes, working: config.workingLook)
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

    /// Places the badge mark at `frame` (the trailing cluster's far right, or the icon's corner
    /// on a tab without a title, TabCell+TrailingMarks); true when it draws (the dot is then skipped).
    func layoutStatusGlyph(frame: CGRect, visible: Bool) -> Bool {
        guard let statusGlyphLayer else { return false }
        statusGlyphLayer.contentsScale = scale
        statusGlyphLayer.layer.opacity = visible ? 1 : 0
        statusGlyphLayer.frame = frame
        return visible
    }
}
