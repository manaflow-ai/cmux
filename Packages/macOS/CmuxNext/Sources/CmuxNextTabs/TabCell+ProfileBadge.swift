import AppKit
import CmuxNextDesign
import QuartzCore

/// The browser profile dot of a tab whose profile differs from the one its
/// workspace gives new tabs (plans/cmux-next/data-model.md section 5).
extension TabCell {
    static let profileDotSize: CGFloat = 6

    func updateProfileBadge() {
        guard item.profileBadge != nil else {
            profileLayer?.removeFromSuperlayer()
            profileLayer = nil
            return
        }
        let dot = profileLayer ?? {
            let dot = CALayer()
            dot.actions = Self.noActions
            dot.cornerRadius = Self.profileDotSize / 2
            layer.addSublayer(dot)
            profileLayer = dot
            return dot
        }()
        themeScope.perform { applyProfileDotColors() }
    }

    /// theme-scoped: callers run it inside `themeScope.perform`.
    /// A colored profile fills the dot; a profile without a color draws a
    /// ring, so it never reads as the unread dot.
    func applyProfileDotColors() {
        guard let dot = profileLayer else { return }
        if let color = item.profileBadge?.color {
            dot.backgroundColor = color.swatch.cgColor
            dot.borderWidth = 0
        } else {
            dot.backgroundColor = nil
            dot.borderWidth = 1
            dot.borderColor = Palette.textTertiary.cgColor
        }
    }

    /// Places the dot at the end of the title area when the title keeps a
    /// few characters; returns where the title must end.
    func layoutProfileBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let profileLayer else { return titleEnd }
        let size = Self.profileDotSize
        guard titleEnd - titleX - size - Metrics.space2 >= 48 else {
            profileLayer.opacity = 0
            return titleEnd
        }
        profileLayer.frame = CGRect(x: pixel(titleEnd - size), y: pixel(midY - size / 2), width: size, height: size)
        profileLayer.opacity = 1
        return titleEnd - size - Metrics.space2
    }
}
