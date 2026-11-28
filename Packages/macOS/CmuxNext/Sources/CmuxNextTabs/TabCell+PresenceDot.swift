import AppKit
import CmuxNextDesign
import QuartzCore

/// The dot of the agent acting in the tab (cx-gg84): a true circle in the
/// agent's presence color at the end of the title, so a background tab shows
/// which agent is in it and that it is acting.
extension TabCell {
    func updatePresenceDot() {
        guard item.presence != nil else {
            presenceLayer?.removeFromSuperlayer()
            presenceLayer = nil
            return
        }
        if presenceLayer == nil {
            let dot = CALayer()
            dot.actions = Self.noActions
            dot.cornerRadius = Self.profileDotSize / 2
            layer.addSublayer(dot)
            presenceLayer = dot
        }
        themeScope.perform { applyPresenceDotColor() }
    }

    /// theme-scoped: callers run it inside `themeScope.perform`.
    func applyPresenceDotColor() {
        guard let presenceLayer, let presence = item.presence else { return }
        presenceLayer.backgroundColor = AgentPresenceColor(key: presence.colorKey).color.cgColor
    }

    /// Places the dot at the end of the title area when the title keeps a
    /// few characters; returns where the title must end.
    func layoutPresenceDot(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let presenceLayer else { return titleEnd }
        let size = Self.profileDotSize
        guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
            presenceLayer.opacity = 0
            return titleEnd
        }
        // Width equals height and the radius is half of it: a true circle.
        presenceLayer.frame = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
        presenceLayer.opacity = 1
        return titleEnd - size - Metrics.space2
    }
}
