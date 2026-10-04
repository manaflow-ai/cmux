public import CmuxNextDesign
public import CoreGraphics

/// Debug Settings tunables of the tab strip (plans/cmux-next/tabs.md). The
/// derived ones compute their default from the density tokens exactly as
/// `TabStripMetrics` always did; the expression lives here once.
public nonisolated enum TabTunables {
    private static func points(_ name: String, _ label: String, help: String, range: ClosedRange<Double> = 0...64,
                               derive: @escaping @MainActor @Sendable () -> CGFloat) -> ComputedTunable {
        ComputedTunable("tabs.\(name)", .tabs, label, help: help, range: range, code: "TabTunables.\(name)", derive: derive)
    }

    // MARK: Strip geometry

    public static let compactTabWidth = points("compactTabWidth", "Compact style tab width", help: "Width of every unpinned tab in compact style. Default: 3/4 of the max width.",
                                               range: 40...400) { (Metrics.tabMaxWidth * 3 / 4).rounded() }
    public static let pinnedGroupGap = points("pinnedGroupGap", "Pinned gap", help: "Extra space after the last pinned tab.") { Metrics.space2 }
    public static let contentTrailingInset = points("contentTrailingInset", "Tab trailing inset", help: "Inset of the close button from a tab's trailing edge.") { Metrics.space2 }
    public static let closeButtonSize = points("closeButtonSize", "Close button size", help: "Side of a tab's close button.") { Metrics.space6 }
    public static let closeGlyphSize = points("closeGlyphSize", "Close glyph size", help: "Side of the x inside the close button.") { Metrics.space4 - Metrics.space1 / 2 }
    public static let iconTitleSpacing = points("iconTitleSpacing", "Icon to title", help: "Gap between a tab's icon and its title.") { Metrics.space3 }
    public static let titleCloseSpacing = points("titleCloseSpacing", "Title to close", help: "Gap between a tab's title and its close button.") { Metrics.space2 }
    public static let titleFadeWidth = points("titleFadeWidth", "Title fade", help: "Length of the fade that clips a long title.") { Metrics.space6 + Metrics.space2 }
    public static let badgeSize = points("badgeSize", "Badge size", help: "Diameter of the unread / status dot.") { Metrics.space3 }
    public static let closeMinContentsWidth = points("closeMinContentsWidth", "Close button threshold", help: "Contents width from which a hovered inactive tab shows its x (Chromium: 68).",
                                                     range: 0...200) { 4 * Metrics.space6 + Metrics.space2 }
    public static let titleMinVisibleWidth = points("titleMinVisibleWidth", "Shortest title", help: "Narrowest title fragment worth showing after the icon.") { Metrics.space5 }
    public static let trailingButtonSpacing = points("trailingButtonSpacing", "Trailing button gap", help: "Gap between the strip's trailing buttons.") { Metrics.space1 }
    public static let trailingGroupGap = points("trailingGroupGap", "Trailing group gap", help: "Space between the tabs and the trailing buttons.") { Metrics.space2 }
    public static let scrollFadeWidth = points("scrollFadeWidth", "Strip scroll fade", help: "Length of the fade on a scrolled strip edge (also the drag autoscroll zone).") { Metrics.space6 + Metrics.space4 }
    public static let separatorHeight = points("separatorHeight", "Separator height", help: "Height of the separator between inactive tabs. Default: half the tab height.") { Metrics.tabHeight / 2 }
    public static let groupChipPadding = points("groupChipPadding", "Group chip padding", help: "Horizontal padding inside a tab group chip.") { Metrics.space3 }
    public static let groupUnderlineHeight = points("groupUnderlineHeight", "Group underline", help: "Height of the line under a tab group's tabs.", range: 0...8) { Metrics.space1 }

    // MARK: Drag and hover

    public static let tearOffDistance = ComputedTunable(
        "tabs.tearOffDistance", .tabDrag, "Tear-off distance", help: "Vertical distance outside the strip that hands a dragged tab to the drag session.",
        range: 0...120, code: "TabTunables.tearOffDistance") { Metrics.space6 + Metrics.space4 }
    public static let dragStartDistance = ComputedTunable(
        "tabs.dragStartDistance", .tabDrag, "Drag start distance", help: "How far a pressed tab moves before it starts dragging.",
        range: 0...40, code: "TabTunables.dragStartDistance") { Metrics.space2 }
    public static let groupJoinHysteresis = Tunable<CGFloat>.number(
        "tabs.groupJoinHysteresis", .tabDrag, "Group join hysteresis", help: "Share of the dragged tab's width it must travel past a group edge to join or leave it.",
        default: 0.3, range: 0...1, step: 0.05, unit: .fraction, code: "TabTunables.groupJoinHysteresis")
    public static let autoscrollGain = Tunable<CGFloat>.number(
        "tabs.autoscrollGain", .tabDrag, "Drag autoscroll speed", help: "Points per second per point the dragged tab sits inside the edge fade.",
        default: 14, range: 1...60, step: 1, unit: .multiplier, code: "TabTunables.autoscrollGain")
    public static let hoverCardMinimumDelay = Tunable<Double>.number(
        "tabs.hoverCard.minimumDelay", .hover, "Hover card delay (narrow tabs)", help: "Delay over the narrowest tabs.",
        default: 0.3, range: 0...2, step: 0.05, unit: .seconds, code: "TabTunables.hoverCardMinimumDelay")
    public static let hoverCardMaximumDelay = Tunable<Double>.number(
        "tabs.hoverCard.maximumDelay", .hover, "Hover card delay (wide tabs)", help: "Delay over full-width tabs.",
        default: 0.8, range: 0...3, step: 0.05, unit: .seconds, code: "TabTunables.hoverCardMaximumDelay")
    public static var all: [TunableDescriptor] {
        [compactTabWidth, pinnedGroupGap, contentTrailingInset, closeButtonSize, closeGlyphSize, iconTitleSpacing, titleCloseSpacing,
         titleFadeWidth, badgeSize, closeMinContentsWidth, titleMinVisibleWidth, trailingButtonSpacing, trailingGroupGap, scrollFadeWidth,
         separatorHeight, groupChipPadding, groupUnderlineHeight, tearOffDistance, dragStartDistance].map(\.descriptor)
            + [groupJoinHysteresis.descriptor, autoscrollGain.descriptor]
            + [hoverCardMinimumDelay, hoverCardMaximumDelay].map(\.descriptor)
    }
}
