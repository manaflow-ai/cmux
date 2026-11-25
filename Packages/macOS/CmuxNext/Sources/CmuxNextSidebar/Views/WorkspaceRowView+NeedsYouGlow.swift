import AppKit
import CmuxNextDesign
import QuartzCore

/// "Needs you" as motion (`notifications.attention.mark` `glow`; Leo 2026-11-19, a look customization off by
/// default), the sidebar's half of `TabCell+NeedsYouGlow`: a row that waits for the person (an error, needs you,
/// or Ready: the states its one badge would say) draws no trailing mark; its fill breathes a soft halo in that
/// mark's color until it is seen. A selected row never glows, so one that still waits once seen shows its badge
/// again. The marks only go transparent, so nothing in the row moves.
///
/// One layer per waiting row, made on first need and removed when it stops. The breath runs on the render server
/// (`MotionGate.attentionBreathAnimation`: three breaths, then the halo rests, so a row that waits for hours costs
/// no frames), again each time its window shows after being covered, and not at all when loops are off.
extension WorkspaceRowView {
    static let needsYouGlowKey = "row.needsYouGlow"

    /// The state the glow stands in for, from the row's badges: the one the badge would show when it asks for
    /// the person; nil for work in progress or nothing.
    static func needsYouTone(_ badges: WorkspaceRowBadges) -> StatusIndicatorState? {
        switch WorkspaceRowBadges.simple(badges.pending) {
        case .error?: .error
        case .waiting?: .waiting(kind: nil)
        case .success?: .success
        case .idle?, .busy?, .paused?, .working?, nil: nil
        }
    }

    /// The row glows in place of its marks: the look is on, it waits for the person, and it is not selected (seen).
    var showsNeedsYouGlow: Bool {
        DesignSettings.shared.attention.mark == .glow && needsYouTone != nil && !showsSelection && !isDropTarget && !isPlaceholderRow
    }

    /// theme-scoped: called from `updateLayer`'s `performWithTheme`. Shows, recolors or removes the halo and hides
    /// the marks it stands in for.
    func updateNeedsYouGlow() {
        let glows = showsNeedsYouGlow
        if glows {
            hideMarksForNeedsYouGlow()
        } else if marksHiddenForGlow {
            marksHiddenForGlow = false
            // The marks come back by the layout's rules, never here: a hovered row keeps them clear under its ✕ and
            // ⋮. Setting them to 1 on every display pass drew the ✕ over the unread dot and the error mark
            // (https://github.com/manaflow-ai/cmux/issues/48363).
            needsLayout = true
        }
        guard glows, let tone = needsYouTone, let host = layer else {
            removeNeedsYouGlow()
            return
        }
        let glow = needsYouGlowLayer ?? makeNeedsYouGlow(in: host)
        let color: NSColor = switch tone {
        case .error: Palette.statusError
        case .waiting: Palette.statusAttention
        default: Palette.statusUnread
        }
        glow.backgroundColor = color.withAlphaComponent(0.16).cgColor
        glow.borderColor = color.withAlphaComponent(0.45).cgColor
        layoutNeedsYouGlow()
        updateNeedsYouGlowMotion()
    }

    /// Clears the marks the halo stands in for. The layout calls it too, after its own mark pass shows them.
    func hideMarksForNeedsYouGlow() {
        marksHiddenForGlow = true
        for mark in [rowBadge, badge, activity] as [NSView] where mark.alphaValue != 0 { mark.alphaValue = 0 }
    }

    /// Fits the halo to the row's fill (`layout`).
    func layoutNeedsYouGlow() {
        guard let glow = needsYouGlowLayer, let host = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = host.bounds
        glow.cornerRadius = fillCornerRadius
        CATransaction.commit()
    }

    private func makeNeedsYouGlow(in host: CALayer) -> CALayer {
        let glow = CALayer()
        glow.actions = ["backgroundColor": NSNull(), "borderColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
        glow.cornerCurve = Metrics.tabCornerCurve
        glow.borderWidth = Metrics.dividerThickness
        host.insertSublayer(glow, at: 0) // over the row's own fill, under its content
        needsYouGlowLayer = glow
        return glow
    }

    func removeNeedsYouGlow() {
        needsYouGlowLayer?.removeFromSuperlayer()
        needsYouGlowLayer = nil
    }

    /// Breathes once per showing (``isNeedsYouWindowVisible``) while loops run, then rests at full strength; a covered
    /// window drops the breath, so the row breathes again when it shows.
    func updateNeedsYouGlowMotion() {
        guard let glow = needsYouGlowLayer else { return }
        guard isNeedsYouWindowVisible, let breath = Motion.indicators.attentionBreathAnimation(low: 0.35) else {
            glow.removeAnimation(forKey: Self.needsYouGlowKey)
            return
        }
        guard glow.animation(forKey: Self.needsYouGlowKey) == nil else { return }
        glow.add(breath, forKey: Self.needsYouGlowKey)
    }
}
