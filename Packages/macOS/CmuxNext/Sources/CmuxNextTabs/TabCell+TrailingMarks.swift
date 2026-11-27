import CmuxNextDesign
import QuartzCore

/// Where a tab's marks draw (Lawrence 2026-10-19: "There should only ever be a single unread
/// indicator for the right side", "nothing should ever be on the left side besides the favicon").
/// The leading slot draws only the favicon or the tab's icon. Every mark draws in one trailing
/// cluster at the end of the title, left of the x, in one order, left to right: the presence dot,
/// the profile dot, the machine badge, the theme swatch, the loading indicator, the speaker,
/// then the unread or status mark at the far right. The unread dot and a status share one mark
/// (`badgeColor`, or a status icon set's glyph), so a tab never draws two.
///
/// A tab too narrow to show its title has no trailing room: there, as before, the loading
/// indicator takes the icon's place and the mark sits on the icon's corner.
extension TabCell {
    /// The trailing cluster, right to left (the order above, reversed).
    enum TrailingMark: CaseIterable {
        case state, audio, loading, theme, machine, profile, presence
    }

    /// Lays the trailing cluster out from `titleEnd` leftward; returns where the title must end.
    /// The state mark and the loading indicator always draw (they say what the tab needs); the
    /// others draw while the title keeps a few characters, as each did alone.
    ///
    /// `statusSlot`: the x's slot, which the tab's status holds (the state mark, else the loading
    /// indicator, centered in it) whether or not the x shows, so the hovered x takes the status's
    /// place and nothing else moves (Leo 2026-11-05). `statusHidden`: the x stands in for the
    /// status there: the state mark and the loading indicator hide, keeping their room;
    /// `animated` fades them on the hover curve.
    func layoutTrailingMarks(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat, onPath: Bool,
                             statusSlot: CGRect? = nil, statusHidden: Bool = false, animated: Bool = false) -> CGFloat {
        // Opacities before this layout, so a hover change fades from what showed.
        let before = Dictionary(uniqueKeysWithValues: statusMarkLayers.map { (ObjectIdentifier($0), $0.opacity) })
        var end = titleEnd
        var spinnerInSlot = false
        if let statusSlot {
            end = min(end, statusSlot.minX - metrics.titleCloseSpacing)
            if hasStateMark {
                _ = placeTrailingStateMark(center: CGPoint(x: statusSlot.midX, y: midY), onPath: onPath)
            } else if spinnerLayer != nil {
                spinnerInSlot = true
                _ = layoutTrailingSpinner(end: statusSlot.midX + spinnerSide / 2, midY: midY)
            }
        }
        for mark in TrailingMark.allCases {
            switch mark {
            case .state: if statusSlot == nil { end = layoutTrailingStateMark(end: end, midY: midY, onPath: onPath) }
            case .audio: end = layoutAudioBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .loading: if !spinnerInSlot { end = layoutTrailingSpinner(end: end, midY: midY) }
            case .theme: end = layoutThemeBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .machine: end = layoutMachineBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .profile: end = layoutProfileBadge(titleX: titleX, titleEnd: end, midY: midY)
            case .presence: end = layoutPresenceDot(titleX: titleX, titleEnd: end, midY: midY)
            }
        }
        // A mark the layout just created (a status arriving under the pointer) has no earlier look to fade from.
        let shown = statusSlot == nil || !statusHidden
        for layer in statusMarkLayers {
            setStatusMark(layer, shown: shown, was: before[ObjectIdentifier(layer)] ?? (shown ? 1 : 0), animated: animated)
        }
        return end
    }

    /// The marks the hovered x stands in for: the status glyph or dot, and the loading indicator unless it is leaving.
    private var statusMarkLayers: [CALayer] {
        [statusGlyphLayer?.layer, badgeLayer, isSpinnerExiting ? nil : spinnerLayer?.layer].compactMap(\.self)
    }

    /// The marks an untitled tab draws on its icon, which give way with the icon when the x takes its slot.
    var iconMarkLayers: [CALayer] { statusMarkLayers + [themeBadgeLayer].compactMap(\.self) }

    /// Shows or hides a status mark the hovered x stands in for. `was`: its opacity before the layout,
    /// which set it shown (or, with `landsShown`, left it as it was); a change fades on the hover curve
    /// when `animated`, else lands at once.
    func setStatusMark(_ layer: CALayer, shown: Bool, was: Float, animated: Bool, landsShown: Bool = false) {
        let target: Float = shown ? 1 : 0
        if animated, was != target {
            Motion.tabs.set(layer, "opacity", to: target, fade: .hover, from: layer.presentation()?.opacity ?? was)
        } else if !shown {
            layer.removeAnimation(forKey: "opacity")
            layer.opacity = 0
        } else if landsShown {
            layer.opacity = 1
        }
    }

    /// The unread or status mark at the cluster's far right.
    private func layoutTrailingStateMark(end: CGFloat, midY: CGFloat, onPath: Bool) -> CGFloat {
        let m = metrics
        let glyphSide = pixel(m.iconSize * 0.62)
        let dot = CGRect(x: pixel(end - m.badgeSize), y: pixel(midY - m.badgeSize / 2), width: m.badgeSize, height: m.badgeSize)
        let glyph = CGRect(x: pixel(end - glyphSide), y: pixel(midY - glyphSide / 2), width: glyphSide, height: glyphSide)
        guard let width = placeStateMark(dot: dot, glyph: glyph, visible: true, onPath: onPath) else { return end }
        return end - width - Metrics.space2
    }

    /// The unread or status mark centered on `center` (the x's slot).
    private func placeTrailingStateMark(center: CGPoint, onPath: Bool) -> CGFloat? {
        let m = metrics
        let glyphSide = pixel(m.iconSize * 0.62)
        let dot = CGRect(x: pixel(center.x - m.badgeSize / 2), y: pixel(center.y - m.badgeSize / 2), width: m.badgeSize, height: m.badgeSize)
        let glyph = CGRect(x: pixel(center.x - glyphSide / 2), y: pixel(center.y - glyphSide / 2), width: glyphSide, height: glyphSide)
        return placeStateMark(dot: dot, glyph: glyph, visible: true, onPath: onPath)
    }

    /// The loading indicator's side in the cluster, the speaker's size class.
    private var spinnerSide: CGFloat { metrics.iconSize - 2 * Metrics.space1 }

    /// The loading indicator left of the state mark, at the speaker's size class.
    private func layoutTrailingSpinner(end: CGFloat, midY: CGFloat) -> CGFloat {
        guard let spinnerLayer else { return end }
        if !isSpinnerExiting { spinnerLayer.layer.opacity = 1 }
        let side = spinnerSide
        spinnerLayer.frame = CGRect(x: pixel(end - side), y: pixel(midY - side / 2), width: side, height: side)
        return end - side - Metrics.space2
    }

    /// The mark on the icon's top trailing corner, for a tab that shows no title.
    func layoutStateMark(iconFrame: CGRect, visible: Bool, onPath: Bool) {
        let badge = metrics.badgeSize
        let dot = CGRect(x: pixel(iconFrame.maxX - badge + Metrics.space1), y: pixel(iconFrame.minY - Metrics.space1), width: badge, height: badge)
        let side = pixel(iconFrame.width * 0.62)
        let glyph = CGRect(x: pixel(iconFrame.maxX - side + Metrics.space1), y: pixel(iconFrame.minY - Metrics.space1), width: side, height: side)
        _ = placeStateMark(dot: dot, glyph: glyph, visible: visible, onPath: onPath)
    }

    /// Draws the one state mark: a status icon set's glyph at `glyph` when one draws, else the
    /// dot at `dot` while `badgeColor` says one shows. Returns the drawn mark's width, nil when none.
    private func placeStateMark(dot: CGRect, glyph: CGRect, visible: Bool, onPath: Bool) -> CGFloat? {
        if layoutStatusGlyph(frame: glyph, visible: visible) { removeBadge(onPath: onPath); return glyph.width }
        guard visible, badgeColor != nil else { removeBadge(onPath: onPath); return nil }
        let badgeLayer = makeBadge()
        badgeLayer.frame = dot
        badgeLayer.cornerRadius = dot.width / 2
        badgeLayer.opacity = 1
        return dot.width
    }

    private func removeBadge(onPath: Bool) {
        guard let badgeLayer else { return }
        if onPath {
            badgeLayer.opacity = 0
        } else {
            badgeLayer.removeFromSuperlayer()
            self.badgeLayer = nil
        }
    }
}
