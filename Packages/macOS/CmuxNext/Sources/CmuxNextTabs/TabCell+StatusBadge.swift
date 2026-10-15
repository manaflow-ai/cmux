import CmuxNextDesign
import QuartzCore

/// The tab's status badge in a status icon set (cx-kxa2): with a candidate
/// set chosen (`StatusIconSet`, Debug Settings `status.iconSet`), needs
/// input, done and failed draw the set's mark (with the OSC 7501 blocked
/// kind) at the icon's corner in place of the colored dot. The default set
/// keeps the dot, so nothing changes until a set is picked. The unread dot
/// is not a status and stays a dot. When sidebar rows show a status icon (Debug Settings
/// `sidebar.rowBadge` Status icon), the mark sits beside the icon or at the title's end instead,
/// on the side `sidebar.statusIconSide` names (`StatusIndicatorConfig.statusSide`), as rows do.
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
        guard let state = statusBadgeState, config.statusSide != nil || config.iconSet != .current else { return nil }
        let plan = StatusIndicatorPlan.make(state, style: config.settings.style, animates: false, set: config.iconSet)
        return plan.glyph == .none ? nil : plan
    }

    /// Creates, updates or removes the badge mark for the item and config.
    /// A cell with a status follows the shared config, so a set switch
    /// restyles it live.
    func updateStatusGlyph() {
        if item.status != .none || item.iconIsKind { StatusIndicatorAppearance.shared.register(self) }
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

    /// The side the mark draws on beside the icon or title (`StatusIndicatorConfig.statusSide`); nil at the icon's corner.
    var statusSide: SidebarStatusIconSide? {
        guard statusGlyphLayer != nil else { return nil }
        return StatusIndicatorAppearance.shared.config.statusSide
    }

    /// The side of a mark that sits beside the icon or the title.
    func statusGlyphSide(iconSide: CGFloat) -> CGFloat { pixel(iconSide * 0.62) }

    /// An agent chat draws no chat icon or agent mark while rows show a status icon, as agent chat
    /// rows draw none (Leo 2026-10-15); a user's own icon still draws.
    var hidesKindIcon: Bool {
        guard item.iconIsKind, StatusIndicatorAppearance.shared.config.statusSide != nil else { return false }
        switch item.icon {
        case .icon(.agentChat), .agentMark: return true
        default: return false
        }
    }

    /// The slot a mark on the left takes before the icon; 0 for any other place, and for an agent
    /// chat, whose mark takes the icon's own slot.
    func statusLeadingSlot(iconSide: CGFloat) -> CGFloat {
        statusSide == .left && visibility.showsIcon && !visibility.centersContent && !hidesKindIcon
            ? statusGlyphSide(iconSide: iconSide) + Metrics.space2 : 0
    }

    /// Where the title starts: after the icon, or where the icon was for an agent chat whose
    /// status icon sits on the right (its left side is empty, as the row's is).
    func titleStart(iconFrame: CGRect, spacing: CGFloat) -> CGFloat {
        hidesKindIcon && StatusIndicatorAppearance.shared.config.statusSide == .right && spinnerLayer == nil
            ? iconFrame.minX : iconFrame.maxX + spacing
    }

    /// Places the badge mark before the icon (`left`) or at the icon's top trailing corner, where
    /// the dot sits. A mark on the right waits for the title (`statusTitleEnd`). Returns whether
    /// it draws (the dot is then skipped).
    func layoutStatusGlyph(iconFrame: CGRect, visible: Bool) -> Bool {
        guard let statusGlyphLayer else { return false }
        statusGlyphLayer.contentsScale = scale
        statusGlyphLayer.layer.opacity = visible ? 1 : 0
        let side = statusGlyphSide(iconSide: iconFrame.width)
        switch statusSide {
        case .right? where visibility.showsTitle:
            return true
        case .left?:
            let x = hidesKindIcon ? iconFrame.midX - side / 2 : iconFrame.minX - Metrics.space2 - side
            statusGlyphLayer.frame = CGRect(x: pixel(x), y: pixel(iconFrame.midY - side / 2), width: side, height: side)
        default:
            // The corner, also for a tab too narrow for its title.
            statusGlyphLayer.frame = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.minY - Metrics.space1),
                                            width: side, height: side)
        }
        return visible
    }

    /// Places a mark on the right at `titleEnd` and returns where the title now ends.
    func statusTitleEnd(iconFrame: CGRect, _ titleEnd: CGFloat) -> CGFloat {
        guard let statusGlyphLayer, statusSide == .right else { return titleEnd }
        let side = statusGlyphSide(iconSide: iconFrame.width)
        statusGlyphLayer.layer.opacity = 1
        statusGlyphLayer.frame = CGRect(x: pixel(titleEnd - side), y: pixel(iconFrame.midY - side / 2), width: side, height: side)
        return titleEnd - side - Metrics.space2
    }
}
