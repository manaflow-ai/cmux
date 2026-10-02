import AppKit
public import CmuxNextDesign
import QuartzCore

/// A terminal with its own theme (plans/cmux-next/data-model.md 6): the
/// theme's name and its background and foreground, for the tab's subtle
/// indicator (a small swatch dot on the icon's lower corner).
public struct TabThemeBadge: Hashable, Sendable {
    public var name: String
    public var background: ThemeRGB
    public var foreground: ThemeRGB

    public init(name: String, background: ThemeRGB, foreground: ThemeRGB) {
        self.name = name
        self.background = background
        self.foreground = foreground
    }
}

extension TabCell {
    /// Adds, updates or removes the swatch dot for `item.themeBadge`. Its
    /// colors are the terminal theme's own, not the strip's scope.
    func updateThemeBadge() {
        guard let badge = item.themeBadge else {
            themeBadgeLayer?.removeFromSuperlayer()
            themeBadgeLayer = nil
            return
        }
        let dot = themeBadgeLayer ?? {
            let dot = CALayer()
            dot.actions = Self.noActions
            dot.borderWidth = Metrics.lineWidth(1)
            layer.addSublayer(dot)
            themeBadgeLayer = dot
            return dot
        }()
        dot.backgroundColor = badge.background.withAlpha(1).cgColor
        dot.borderColor = badge.foreground.withAlpha(0.85).cgColor
        dot.contentsScale = scale
    }

    /// Places the dot on the icon's lower trailing corner.
    func layoutThemeBadge(iconFrame: CGRect, visible: Bool) {
        guard let themeBadgeLayer else { return }
        let side = metrics.badgeSize
        themeBadgeLayer.frame = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1),
                                       y: pixel(iconFrame.maxY - side + Metrics.space1), width: side, height: side)
        themeBadgeLayer.cornerRadius = side / 2
        themeBadgeLayer.opacity = visible ? 1 : 0
    }
}
