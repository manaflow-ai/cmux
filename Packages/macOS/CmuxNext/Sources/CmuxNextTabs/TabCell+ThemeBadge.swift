import AppKit
public import CmuxNextDesign
import QuartzCore

/// A terminal with its own theme (plans/cmux-next/data-model.md 6): the
/// theme's name and its background and foreground, for the tab's subtle
/// indicator (a small swatch dot in the trailing cluster, TabCell+TrailingMarks).
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

    /// The swatch's frame on the icon's lower trailing corner, for a tab without a title.
    func themeBadgeIconFrame(iconFrame: CGRect) -> CGRect {
        let side = metrics.badgeSize
        return CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.maxY - side + Metrics.space1), width: side, height: side)
    }

    /// Places the swatch at `frame`.
    func layoutThemeBadge(frame: CGRect, visible: Bool) {
        guard let themeBadgeLayer else { return }
        themeBadgeLayer.frame = frame
        themeBadgeLayer.cornerRadius = frame.width / 2
        themeBadgeLayer.opacity = visible ? 1 : 0
    }

    /// Places the swatch in the trailing cluster (TabCell+TrailingMarks) when the title keeps a
    /// few characters; returns where the title must end.
    func layoutThemeBadge(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard let themeBadgeLayer else { return titleEnd }
        let side = metrics.badgeSize
        guard titleEnd - titleX - side - Metrics.space2 >= 48 else {
            themeBadgeLayer.opacity = 0
            return titleEnd
        }
        layoutThemeBadge(frame: CGRect(x: pixel(titleEnd - side), y: pixel(midY - side / 2), width: side, height: side), visible: true)
        return titleEnd - side - Metrics.space2
    }
}
