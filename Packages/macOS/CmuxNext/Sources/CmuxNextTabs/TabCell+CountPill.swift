import AppKit
import CmuxNextDesign
import QuartzCore

/// An agent chat's count pill (`experiments.agentBadges`, taste build 5, Leo 2026-11-19: "Neutral count pill for
/// unread agent messages or pending approvals, width reserved so tabs never shift"): a grey capsule with the count in
/// secondary text, at the trailing cluster's far right, left of the x's slot. While the experiment is on, every agent
/// chat tab (``TabItem/agentBadgeCount`` not nil) reserves the slot ``TabCountPill/slotWidth(font:)`` wide, the width
/// of "99+", whether its count is 0 or 120: the tab's width and its title's end never move as the count comes,
/// changes or goes. The pill takes the unread dot's place (``TabCell/showsUnreadDot``); a status keeps its mark.
/// Off, no pill and no slot: the shipped tab.
enum TabCountPill {
    /// Counts above this read "99+".
    static let cap = 99

    /// The count as the pill reads it; nil draws no pill (0 or less).
    static func label(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > cap ? "\(cap)+" : String(count)
    }

    /// The pill's text: caption size with tabular digits, so "11" and "88" are one width.
    @MainActor static var font: NSFont { Typography.captionDigits }

    /// Space between the pill's text and its ends.
    @MainActor static var padding: CGFloat { Metrics.space3 }

    /// One line of `font`.
    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// The pill's height: a line of its text and a little air, never taller than the line plus `padding`.
    @MainActor static func height(font: NSFont) -> CGFloat {
        lineHeight(font) + Metrics.space1
    }

    /// The text's drawn width.
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The pill's width for `text`: the text and its padding, never narrower than tall (a single digit is a circle).
    @MainActor static func width(_ text: String, font: NSFont) -> CGFloat {
        max(height(font: font), textWidth(text, font: font) + 2 * padding)
    }

    /// The slot an agent tab reserves: the widest pill (`"99+"`), whatever the count is now.
    @MainActor static func slotWidth(font: NSFont) -> CGFloat {
        width("\(cap)+", font: font)
    }
}

extension TabCell {
    /// The experiment is on and this tab is an agent chat: it reserves the pill's slot.
    var showsCountPill: Bool {
        metrics.agentBadges.showsPills && item.agentBadgeCount != nil && !item.isPinned
    }

    /// The pill draws where the unread dot would, in the trailing cluster of a tab that shows its title at rest
    /// (a pinned or crowded untitled tab keeps the dot on its icon: no pill fits there).
    var countPillReplacesDot: Bool {
        guard showsCountPill else { return false }
        return TabChromeVisibility.resolve(width: bounds.width, isPinned: item.isPinned, isSelected: isSelected, isHovered: false,
                                           isClosable: item.isClosable, style: style, metrics: metrics).showsTitle
    }

    /// The unread dot draws: the tab is unread and no count pill stands in for it.
    var showsUnreadDot: Bool { item.isUnread && !countPillReplacesDot }

    /// The count changed from `old`: the pill fades in from 0, out to 0, and crossfades a new number in place
    /// (Motion `tabs`, `crossfade`; at once with fades off). Never a pop-in, never a move: the slot holds.
    /// `animated` false (a new cell): the pill takes its look at once (`layoutCountPill`).
    func updateCountPill(from old: Int?, animated: Bool) {
        guard showsCountPill else { removeCountPill(); return }
        let pill = makeCountPill()
        let before = TabCountPill.label(old ?? 0)
        let after = TabCountPill.label(item.agentBadgeCount ?? 0)
        guard before != after else { return }
        // Going to 0, the old number stays drawn while it fades out.
        if let after { countPillText(pill)?.string = after }
        guard animated else { return }
        switch (before, after) {
        case (nil, .some):
            Motion.tabs.set(pill, "opacity", to: Float(1), fade: .crossfade, from: Float(0))
        case (.some, nil):
            Motion.tabs.set(pill, "opacity", to: Float(0), fade: .crossfade, from: pill.presentation()?.opacity ?? 1)
        default:
            Motion.tabs.crossfadeInPlace(pill)
        }
    }

    /// Places the pill right-aligned in its reserved slot at `titleEnd`; returns where the title must end. The slot
    /// is the same width for every count (``TabCountPill/slotWidth(font:)``), and is kept with the count at 0.
    func layoutCountPill(titleX: CGFloat, titleEnd: CGFloat, midY: CGFloat) -> CGFloat {
        guard showsCountPill else { removeCountPill(); return titleEnd }
        let pill = makeCountPill()
        let font = TabCountPill.font
        let slot = TabCountPill.slotWidth(font: font)
        // No room for the slot and a sliver of title: the pill hides and the title keeps the room.
        guard titleEnd - slot - Metrics.space2 >= titleX else {
            pill.removeAnimation(forKey: "opacity")
            pill.opacity = 0
            return titleEnd
        }
        let text = TabCountPill.label(item.agentBadgeCount ?? 0)
        if let text {
            let height = TabCountPill.height(font: font)
            let width = TabCountPill.width(text, font: font)
            pill.frame = CGRect(x: pixel(titleEnd - width), y: pixel(midY - height / 2), width: width, height: height)
            pill.cornerRadius = height / 2
            if let label = countPillText(pill) {
                label.contentsScale = scale
                if label.font != font { label.font = font }
                if label.string != text { label.string = text }
                let line = TabCountPill.lineHeight(font)
                label.frame = CGRect(x: 0, y: pixel((height - line) / 2), width: width, height: line)
            }
        }
        // A fade (`updateCountPill`) owns the opacity while it runs; its model value is already the target.
        if pill.animation(forKey: "opacity") == nil { pill.opacity = text == nil ? 0 : 1 }
        return titleEnd - slot - Metrics.space2
    }

    /// The pill's colors: secondary text on the neutral count fill. theme-scoped: callers run it inside `themeScope.perform`.
    func applyCountPillColors() {
        guard let countPillLayer else { return }
        countPillLayer.backgroundColor = Palette.badgeFill.cgColor
        countPillText(countPillLayer)?.foregroundColor = Palette.textSecondary.cgColor
    }

    private func makeCountPill() -> CALayer {
        if let countPillLayer { return countPillLayer }
        let pill = CALayer()
        pill.actions = Self.noActions
        pill.cornerCurve = .continuous
        pill.opacity = 0
        let label = ChromeTextLayer()
        label.actions = Self.noActions
        label.alignmentMode = .center
        label.font = TabCountPill.font
        label.contentsScale = scale
        label.string = TabCountPill.label(item.agentBadgeCount ?? 0) ?? ""
        pill.addSublayer(label)
        layer.insertSublayer(pill, below: titleLayer)
        countPillLayer = pill
        themeScope.perform { applyCountPillColors() }
        return pill
    }

    private func countPillText(_ pill: CALayer) -> ChromeTextLayer? {
        pill.sublayers?.first as? ChromeTextLayer
    }

    private func removeCountPill() {
        countPillLayer?.removeFromSuperlayer()
        countPillLayer = nil
    }
}
