import AppKit
import CmuxNextDesign
import QuartzCore

/// "Needs you" as motion (`notifications.attention.mark` `glow`; Leo 2026-11-19, a look customization off by
/// default): a tab that waits for the person draws no unread or status mark; its pill breathes a soft halo in
/// the mark's color until it is seen. The selected tab never glows (it is being looked at), so a tab that
/// still waits once seen shows its mark again; the mark keeps its room throughout, so nothing moves.
///
/// One layer per waiting tab, made on first need and removed when it stops (architecture.md 3): a wash and a
/// hairline edge in the mark's color, no shadow (a shadow without a path is an offscreen pass per frame, and a
/// path would not follow a moving width). The breath runs on the render server (`MotionGate.attentionBreathAnimation`:
/// three breaths, then the halo rests, so a tab that waits for hours costs no frames; again each time it shows),
/// never per frame on the main thread, and holds still while the window is covered or the strip hidden, and
/// when loops are off (Reduce Motion, speed off; the indicator config and its resync reach each cell).
extension TabCell {
    static let needsYouGlowKey = "tab.needsYouGlow"
    /// The halo's lowest opacity in a breath: it never fully goes, so a glance always finds it.
    static let needsYouGlowLow: Float = 0.35

    /// The tab glows in place of its mark: the look is on, it has a mark to replace, and it is not the selected
    /// (seen) tab. A lifted or closing tab keeps what it showed.
    var showsNeedsYouGlow: Bool {
        DesignSettings.shared.attention.mark == .glow && !isSelected && badgeColor != nil
    }

    /// Places the halo on the pill `pill`, or removes it when the tab does not glow (`onPath`: hides it, as
    /// every part on a moving width's sample does, breath included; the rest layout at the path's end removes it).
    func layoutNeedsYouGlow(pill: CGRect, onPath: Bool) {
        guard showsNeedsYouGlow else {
            guard let glow = needsYouGlowLayer else { return }
            if onPath {
                glow.removeAnimation(forKey: Self.needsYouGlowKey)
                glow.opacity = 0
            } else {
                removeNeedsYouGlow()
            }
            return
        }
        let glow = needsYouGlowLayer ?? makeNeedsYouGlow()
        glow.opacity = 1
        glow.frame = pill
        glow.cornerRadius = metrics.cornerRadius
        glow.cornerCurve = Metrics.tabCornerCurve
        updateNeedsYouGlowMotion()
    }

    private func makeNeedsYouGlow() -> CALayer {
        let glow = CALayer()
        glow.actions = Self.noActions
        glow.borderWidth = Metrics.dividerThickness
        layer.insertSublayer(glow, below: backgroundLayer)
        needsYouGlowLayer = glow
        applyNeedsYouGlowColor()
        return glow
    }

    private func removeNeedsYouGlow() {
        needsYouGlowLayer?.removeFromSuperlayer()
        needsYouGlowLayer = nil
    }

    /// theme-scoped: called inside `themeScope.perform`, or resolves its own scope.
    func applyNeedsYouGlowColor() {
        guard let needsYouGlowLayer else { return }
        themeScope.perform {
            let color = badgeColor ?? Palette.statusAttention
            needsYouGlowLayer.backgroundColor = color.withAlphaComponent(0.16).cgColor
            needsYouGlowLayer.borderColor = color.withAlphaComponent(0.45).cgColor
        }
    }

    /// Breathes once per showing while the tab is on screen and loops run, then rests at full strength; a covered
    /// window or hidden strip drops the breath, so the tab breathes again when it shows.
    func updateNeedsYouGlowMotion() {
        guard let glow = needsYouGlowLayer else { return }
        guard isWindowVisible, isStripShown, let breath = Motion.indicators.attentionBreathAnimation(low: Self.needsYouGlowLow) else {
            glow.removeAnimation(forKey: Self.needsYouGlowKey)
            return
        }
        guard glow.animation(forKey: Self.needsYouGlowKey) == nil else { return }
        glow.add(breath, forKey: Self.needsYouGlowKey)
    }
}
