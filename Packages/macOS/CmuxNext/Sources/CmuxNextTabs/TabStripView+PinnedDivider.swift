import AppKit
import CmuxNextDesign
import QuartzCore

/// The line that ends the pinned group (Lawrence msg 20243: the pinned icon-only tabs sat against the
/// first normal tab). It sits in ``TabStripMetrics/pinnedGroupGap`` with the gap between two tabs on
/// each side, and shows whatever is selected or hovered beside it: it marks the group, not a tab.
extension TabStripView {
    /// The divider layer's name, for tests and `debug.layers`.
    static let pinnedDividerName = "tabs.pinnedDivider"

    /// Hidden until a strip has pinned and normal tabs.
    static func makePinnedDivider() -> CALayer {
        let line = CALayer()
        line.name = pinnedDividerName
        line.isHidden = true
        line.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "backgroundColor": NSNull()]
        return line
    }

    /// Centers the divider between the last pinned tab's pill and the first normal tab, in the pinned
    /// tabs' coordinates (fixed with the pinned band, or scrolling with it when nothing is fixed).
    /// With `move` (a close, an open, a reorder), it slides from where it showed on the same move as the
    /// tabs beside it, so it never lies over a pinned tab's pill; `scroll` is the share of its change
    /// the pinned region's scroll made (`TabStripMove.addScroll`).
    /// `crossing`: the tabs a pin or an unpin flies (`flyPinnedTabs`): the divider fades around them instead of sliding
    /// through them (`addPinnedDividerCrossing`).
    func layoutPinnedDivider(mapping: TabScrollMapping, tabY: CGFloat, tabHeight: CGFloat, pixel: (CGFloat) -> CGFloat,
                             move: TabStripMove? = nil, scroll: CGFloat = 0, crossing: [CALayer] = []) {
        let slots = result.slots.filter { !$0.isCollapsed }
        guard metrics.showsPinnedDivider,
              let firstNormal = slots.firstIndex(where: { !$0.isPinned }), firstNormal > 0, slots[firstNormal - 1].isPinned,
              let pinned = placed[slots[firstNormal - 1].id], let normal = placed[slots[firstNormal].id]
        else {
            // A move still on it would show at its next place plus the old offset.
            if !pinnedDivider.isHidden { TabStripMove.cancel(pinnedDivider) }
            pinnedDivider.isHidden = true
            return
        }
        let line: CGFloat = 1
        let pillEnd = pinned.maxX - 2 * metrics.tabBackgroundInset
        let x = mapping.viewX(pillEnd + (normal.x - pillEnd - line) / 2, isPinned: true)
        let height = pixel(min(metrics.separatorHeight, tabHeight))
        let wasShown = !pinnedDivider.isHidden
        let from = pinnedDivider.position
        // Where it shows now, read before its model moves: a crossing's keyframes hold its x and opacity apart from the model.
        let now = CACurrentMediaTime()
        let shownX = wasShown ? MotionPath(pinnedDivider, "position").value(at: now).x : from.x
        let shownOpacity = wasShown ? Self.shownOpacity(of: pinnedDivider, at: now) : 0
        pinnedDivider.frame = CGRect(x: pixel(x), y: pixel(tabY + (tabHeight - height) / 2), width: line, height: height)
        pinnedDivider.isHidden = false
        if let move, !crossing.isEmpty {
            // A relayout while the crossing runs that keeps its new place (the app's second sync of the same pin, the daemon's
            // echo) keeps that crossing: one restarted from the model, already at the new place, showed the divider there at
            // once and drew it through the tab sliding under it, then hid it (the film at a4ccec2: tab1's icon, 3 frames).
            if let target = crossingTarget, abs(target - pinnedDivider.position.x) < 0.5 { return }
            TabStripMove.cancel(pinnedDivider)
            let neighbours = cells.compactMap { id, cell in
                cell.layer.isHidden || dying.contains(id) || crossing.contains { $0 === cell.layer } ? nil : cell.layer
            }
            // A new place mid-crossing (pin again, unpin): from where it shows, at the opacity it shows.
            addPinnedDividerCrossing(move, from: shownX - scroll, wasShown: shownOpacity > 0.05, fromOpacity: shownOpacity,
                                     crossing: crossing, neighbours: neighbours)
            return
        }
        // A divider that just showed is at its place at once, as a new tab's separator is.
        guard let move, wasShown else { return }
        let delta = CGPoint(x: from.x - pinnedDivider.position.x - scroll, y: from.y - pinnedDivider.position.y)
        if abs(delta.x) > 0.01 || abs(delta.y) > 0.01 {
            move.add(move.motion.additive("position", from: NSValue(point: delta), to: NSValue(point: .zero)), to: pinnedDivider, as: "divider")
        }
        move.addScroll(scroll, to: pinnedDivider)
    }

    /// The x a running crossing ends at (its last keyframe), nil when none runs.
    var crossingTarget: CGFloat? {
        let key = pinnedDivider.animationKeys()?.first { $0.hasPrefix(TabStripMove.keyPrefix) && $0.hasSuffix(".divider.crossing.position") }
        guard let key, let frames = pinnedDivider.animation(forKey: key) as? CAKeyframeAnimation,
              let last = frames.values?.last as? NSValue else { return nil }
        return last.pointValue.x
    }

    /// `layer`'s opacity at `time`: its model's, or the value a running opacity keyframe move gives it then (`MotionPath`
    /// reads geometry only).
    static func shownOpacity(of layer: CALayer, at time: CFTimeInterval) -> Float {
        var value = layer.opacity
        for key in layer.animationKeys() ?? [] {
            guard let animation = layer.animation(forKey: key) as? CAKeyframeAnimation, animation.keyPath == "opacity",
                  let values = animation.values as? [NSNumber], let first = values.first, let last = values.last else { continue }
            let begin = layer.convertTime(animation.beginTime, to: nil)
            guard time >= begin else { value = first.floatValue; continue }
            let t = min(1, (time - begin) / max(animation.duration, .ulpOfOne))
            guard t < 1 else { value = last.floatValue; continue }
            let times = animation.keyTimes?.map(\.doubleValue) ?? values.indices.map { Double($0) / Double(max(1, values.count - 1)) }
            let index = max(0, min(values.count - 2, (times.lastIndex { $0 <= t }) ?? 0))
            let span = max(times[index + 1] - times[index], .ulpOfOne)
            let f = Float(min(1, max(0, (t - times[index]) / span)))
            value = values[index].floatValue + (values[index + 1].floatValue - values[index].floatValue) * f
        }
        return value
    }

    /// The theme's separator tone at the tab separators' strength; clear under `appearance.borders` none.
    func applyPinnedDividerColor() {
        pinnedDivider.backgroundColor = themeScope.perform {
            Borders.color(Palette.separator.withAlphaComponent(metrics.separatorOpacity)).cgColor
        }
    }
}
