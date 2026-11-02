public import CmuxNextDesign
public import CoreGraphics

/// Prototype transitions for a tab's loading indicator. The default is
/// `instant`, which preserves the existing behavior; the other choices keep
/// the tab's geometry fixed while the indicator enters or leaves.
public nonisolated enum TabLoadingAnimation: String, Sendable, CaseIterable, TunableChoice {
    /// The current behavior: the spinner appears or disappears in one frame.
    case instant
    /// A short opacity-only fade.
    case fade
    /// Fade with a tiny scale-up/down around the icon's center.
    case fadeScale
    /// Fade with a two-point vertical settle.
    case fadeSlide

    public var tunableTitle: String {
        switch self {
        case .instant: "Instant"
        case .fade: "Fade"
        case .fadeScale: "Fade + scale"
        case .fadeSlide: "Fade + slide"
        }
    }
}

/// What the tab bar's trailing controls (the plus, the pane's pins and "…") show at rest
/// (`TabTunables.crowdedControls`). Their room is kept either way, so no tab moves on hover.
public nonisolated enum TabCrowdedControls: String, Sendable, CaseIterable, TunableChoice {
    /// Hidden at rest while the tabs leave room beside them; muted at rest once the tabs fill the
    /// bar, so the room they keep never reads as an empty strip (Leo 2026-10-20).
    case shownWhenCrowded
    /// Muted at rest whatever the tab count (Leo 2026-10-19).
    case alwaysShown
    /// Hidden at rest whatever the tab count (Lawrence 2026-10-20).
    case hiddenAtRest

    public var tunableTitle: String {
        switch self {
        case .shownWhenCrowded: "Shown when the tabs fill the bar"
        case .alwaysShown: "Always shown"
        case .hiddenAtRest: "Hidden at rest"
        }
    }
}

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
    // Scrolling tabs (`tabs.overflow` scroll, cx-kp9b4): Chrome's scrollable tab strip keeps tabs this
    // wide and scrolls; 7/10 of the max width (140 compact, 168 comfortable) shows a whole short title.
    public static let scrollTabMinWidth = points("scrollTabMinWidth", "Scrolling tab width", help: "Narrowest an unpinned tab gets with Tab Overflow set to Scroll. Default: 7/10 of the max width.",
                                                 range: 40...400) { (Metrics.tabMaxWidth * 7 / 10).rounded() }
    public static let pinnedGroupGap = points("pinnedGroupGap", "Pinned gap", help: "Extra space after the last pinned tab.") { Metrics.space2 }
    public static let contentTrailingInset = points("contentTrailingInset", "Tab trailing inset", help: "Inset of the close button from a tab's trailing edge.") { Metrics.space2 }
    public static let closeButtonSize = points("closeButtonSize", "Close button size", help: "Side of a tab's close button.") { Metrics.space6 }
    public static let closeGlyphSize = points("closeGlyphSize", "Close glyph size", help: "Side of the x inside the close button.") { Metrics.space4 - Metrics.space1 / 2 }
    public static let iconTitleSpacing = points("iconTitleSpacing", "Icon to title", help: "Gap between a tab's icon and its title.") {
        Metrics.compactTabs ? Metrics.space2 : Metrics.space3
    }
    public static let titleCloseSpacing = points("titleCloseSpacing", "Title to close", help: "Gap between a tab's title and its close button.") { Metrics.space2 }
    public static let titleFadeWidth = points("titleFadeWidth", "Title fade", help: "Length of the fade that clips a long title.") { Metrics.space6 + Metrics.space2 }
    public static let badgeSize = points("badgeSize", "Badge size", help: "Diameter of the unread / status dot.") { Metrics.space3 }
    public static let closeMinContentsWidth = points("closeMinContentsWidth", "Close button threshold", help: "Contents width from which a hovered inactive tab shows its x (Helium: 56; Chromium: 68).",
                                                     range: 0...200) { 3 * Metrics.space6 + Metrics.space4 }
    public static let titleMinVisibleWidth = points("titleMinVisibleWidth", "Shortest title", help: "Narrowest title fragment worth showing after the icon.") { Metrics.space5 }
    public static let scrollFadeWidth = points("scrollFadeWidth", "Strip scroll fade", help: "Length of the fade on a scrolled strip edge (also the drag autoscroll zone).") { Metrics.space6 + Metrics.space4 }
    public static let groupChipPadding = points("groupChipPadding", "Group chip padding", help: "Horizontal padding inside a tab group chip.") { Metrics.space3 }
    public static let separatorHeight = points("separatorHeight", "Separator height", help: "Height of the line between tabs. Default: 55% of the tab height.") {
        (Metrics.tabHeight * 0.55).rounded()
    }
    // @intent Leo 2026-10-14 asked for lines between tabs; Lawrence removed them in 7f9fc1ed, so they
    // stay opt-in until the default call is made.
    public static let separators = Tunable<Bool>.toggle(
        "tabs.separators", .tabs, "Tab separators",
        help: "A short line between tabs, hidden beside the selected and the hovered tab.",
        default: false, code: "TabTunables.separators")
    public static let separatorOpacity = Tunable<CGFloat>.number(
        "tabs.separatorOpacity", .tabs, "Separator strength", help: "Opacity of the theme's separator tone in the line between tabs.",
        default: 0.2, range: 0...1, step: 0.02, unit: .fraction, code: "TabTunables.separatorOpacity")
    // @intent Lawrence 2026-10-20 ("the plus and dropdown and 3 dots [must] not appear unless hovered in
    // tabbar area") over Leo 2026-10-19 (muted at rest): hidden at rest, shown on tab bar hover. A value
    // above 0 shows them muted at rest again.
    public static let restingControlOpacity = Tunable<CGFloat>.number(
        "tabs.restingControlOpacity", .tabs, "Tab bar controls at rest",
        help: "Opacity of the tab bar's plus and More while the pointer is elsewhere; hover shows them fully. 0 hides them.",
        default: 0, range: 0...1, step: 0.05, unit: .fraction, code: "TabTunables.restingControlOpacity")
    // @intent Leo 2026-10-20 ("the rightmost area has a reservation of hidden icons"; "if you push or hover
    // then you cant access the rightmost tabs"): the room stays (no push, no overlay), and once the tabs
    // fill the bar its controls show muted at rest instead of leaving an empty strip.
    public static let crowdedControls = Tunable<TabCrowdedControls>.choice(
        "tabs.crowdedControls", .tabs, "Tab bar controls when crowded",
        help: "Whether the plus and More show at rest once the tabs fill the bar, so their kept room is never an empty strip.",
        default: .shownWhenCrowded, code: "TabTunables.crowdedControls")
    public static let crowdedControlOpacity = Tunable<CGFloat>.number(
        "tabs.crowdedControlOpacity", .tabs, "Tab bar controls at rest, crowded",
        help: "Opacity of the tab bar's plus and More at rest while they show at rest (Tab bar controls when crowded).",
        default: 0.5, range: 0...1, step: 0.05, unit: .fraction, code: "TabTunables.crowdedControlOpacity")

    /// The trailing controls' opacity at rest; `crowded`: the tabs fill the bar (``TabStripView/isCrowded``).
    public static func restingControlAlpha(crowded: Bool, in store: TunableStore = .shared) -> CGFloat {
        let rest = restingControlOpacity.value(in: store), shown = max(rest, crowdedControlOpacity.value(in: store))
        switch crowdedControls.value(in: store) {
        case .hiddenAtRest: return rest
        case .alwaysShown: return shown
        case .shownWhenCrowded: return crowded ? shown : rest
        }
    }
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
    // @intent Leo 2026-10-14 asked for Hover Previews: Compact / Full. A tunable until the settings
    // freeze lifts; the persisted `tabs.hoverPreviews` setting is the follow-up.
    public static let hoverPreviews = Tunable<TabHoverPreviews>.choice(
        "tabs.hoverPreviews", .tabs, "Tab hover previews",
        help: "Full shows a thumbnail on a tab's hover card; Compact shows only its facts.",
        default: .full, code: "TabTunables.hoverPreviews")
    /// Debug-only loading transition prototypes. Instant is the production
    /// default until one of the variants is selected for dogfood.
    public static let loadingAnimation = Tunable<TabLoadingAnimation>.choice(
        "tabs.loadingAnimation", .tabs, "Tab loading animation",
        help: "Prototype for a busy tab's indicator entering or leaving. Instant preserves the current behavior.",
        default: .instant, code: "TabTunables.loadingAnimation")
    public static var all: [TunableDescriptor] {
        [compactTabWidth, scrollTabMinWidth, pinnedGroupGap, contentTrailingInset, closeButtonSize, closeGlyphSize, iconTitleSpacing, titleCloseSpacing,
         titleFadeWidth, badgeSize, closeMinContentsWidth, titleMinVisibleWidth, scrollFadeWidth,
         separatorHeight, groupChipPadding, groupUnderlineHeight, tearOffDistance, dragStartDistance].map(\.descriptor)
            + [separators.descriptor, separatorOpacity.descriptor, restingControlOpacity.descriptor, crowdedControls.descriptor,
               crowdedControlOpacity.descriptor, groupJoinHysteresis.descriptor, autoscrollGain.descriptor,
               hoverPreviews.descriptor, loadingAnimation.descriptor]
    }
}
