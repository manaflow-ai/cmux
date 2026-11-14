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
    func layoutPinnedDivider(mapping: TabScrollMapping, tabY: CGFloat, tabHeight: CGFloat, pixel: (CGFloat) -> CGFloat,
                             move: TabStripMove? = nil, scroll: CGFloat = 0) {
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
        pinnedDivider.frame = CGRect(x: pixel(x), y: pixel(tabY + (tabHeight - height) / 2), width: line, height: height)
        pinnedDivider.isHidden = false
        // A divider that just showed is at its place at once, as a new tab's separator is.
        guard let move, wasShown else { return }
        let delta = CGPoint(x: from.x - pinnedDivider.position.x - scroll, y: from.y - pinnedDivider.position.y)
        if abs(delta.x) > 0.01 || abs(delta.y) > 0.01 {
            move.add(move.motion.additive("position", from: NSValue(point: delta), to: NSValue(point: .zero)), to: pinnedDivider, as: "divider")
        }
        move.addScroll(scroll, to: pinnedDivider)
    }

    /// The theme's separator tone at the tab separators' strength; clear under `appearance.borders` none.
    func applyPinnedDividerColor() {
        pinnedDivider.backgroundColor = themeScope.perform {
            Borders.color(Palette.separator.withAlphaComponent(metrics.separatorOpacity)).cgColor
        }
    }
}
