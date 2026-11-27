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

/// Where a titled tab's trailing status mark sits (the spinner, the unread or status dot), `TabTunables.statusMarkPlacement`;
/// the tab bar playground's Status Spacing page compares them. Leo 2026-10-22 (ask-a8b97f1201): "... + the spacing is off".
public nonisolated enum TabStatusMarkPlacement: String, Sendable, CaseIterable, TunableChoice {
    /// Before: centered in the x's slot, 13 pt from the pill's end at Default, nearer the edge than the icon is to the start.
    case closeSlot
    /// The mark mirrors the icon: its center as far from the trailing edge as the icon's from the leading one. The
    /// hovered x keeps its own place.
    case mirrorIcon
    /// The mark and the hovered x both mirror the icon.
    case mirrorAll

    public var tunableTitle: String {
        switch self {
        case .closeSlot: "Before: in the close button's slot"
        case .mirrorIcon: "Mirrors the icon"
        case .mirrorAll: "Mark and close button mirror the icon"
        }
    }
}

/// How a busy tab with unread output draws its two states (`TabTunables.busyUnreadMark`; the tab bar playground's
/// Busy + Unread page compares them). Leo 2026-10-22 (ask-a8b97f1201): "the tab unread + simultaneous ongoing thing
/// feels weird idk if there is a way to combine + the spacing is off". Every look but `pair` draws one mark in the
/// status slot (the x's), so the unread dot takes the spinner's place when the work ends and nothing moves.
public nonisolated enum TabBusyUnreadMark: String, Sendable, CaseIterable, TunableChoice {
    /// The spinner alone in the status slot while the work runs; the unread dot takes its place when it ends.
    case spinner
    /// The spinner in the status slot, drawn in the unread dot's blue while the tab has unread output.
    case tintedSpinner
    /// The spinner in the status slot ringing a small unread dot at its center.
    case dotInRing
    /// Before: the unread dot in the status slot and the spinner beside it.
    case pair

    public var tunableTitle: String {
        switch self {
        case .spinner: "Spinner, then the dot in its place"
        case .tintedSpinner: "Spinner in the unread blue"
        case .dotInRing: "Spinner ringing the unread dot"
        case .pair: "Before: dot and spinner side by side"
        }
    }
}

/// How a hovered tab's x takes its status's slot (`TabStripMetrics.hoverCloseSwap`; the tab bar
/// playground's Hover Close page compares them). In every treatment but `beside` only the x shows on
/// hover, in the slot the spinner or status mark holds at rest (Leo 2026-11-05).
public nonisolated enum TabHoverCloseSwap: String, Sendable, CaseIterable {
    /// The status fades out on the hover curve while the x fades in, and back on leaving.
    case crossFade
    /// The status gives way at once and the x fades in, as a sidebar workspace row's hover controls.
    case instant
    /// As `crossFade`, with the x's hover fill drawn while it stands in for the status.
    case disc
    /// Before: the x appears beside the status. The playground's comparison only.
    case beside
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
    // @intent Lawrence msg 20243: the pinned group ends in a divider with the gap between two tabs on
    // each side of it, so the extra space is one tab gap plus the hairline.
    public static let pinnedGroupGap = points("pinnedGroupGap", "Pinned gap", help: "Extra space after the last pinned tab, for its divider. Default: the gap between two tabs plus the line.") {
        2 * Metrics.tabBackgroundInset + 1
    }
    // @intent Lawrence 2026-11-13: "need to match the X icon on helium in terms of hover too (like roundness of it), should
    // be applied to all densities". Helium's x on its 28 pt tab (2x captures of Helium 0.21.3.1): a 14 pt hover square 6 pt
    // inside the pill's end, 8 pt of ink; the same shares of the tab at every density (`HeliumTabCloseButtonTests`).
    public static let contentTrailingInset = points("contentTrailingInset", "Tab trailing inset", help: "Inset of the close button from a tab's trailing edge. Default: Helium's 6 on a 28 pt tab.") {
        BrowserChromeTuning.value(.closeTrailing)
    }
    public static let closeButtonSize = points("closeButtonSize", "Close button size", help: "Side of a tab's close button (its hover square). Default: Helium's 14 on a 28 pt tab.") {
        BrowserChromeTuning.value(.closeSize)
    }
    public static let closeGlyphSize = points("closeGlyphSize", "Close glyph size", help: "Side of the x's ink inside the close button. Default: Helium's 8 on a 28 pt tab.") {
        BrowserChromeTuning.value(.closeInk)
    }
    public static let iconTitleSpacing = points("iconTitleSpacing", "Icon to title", help: "Gap between a tab's icon and its title.") {
        Metrics.compactTabs ? Metrics.space2 : (Metrics.densityToken("tabIconTitleGap") ?? Metrics.space3)
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
    // @intent Lawrence 2026-11-05: "for horizontal tabs, we should have subtle border between all the
    // tabs (and also between the last tab and plus button)". On by default; hidden only beside the
    // selected tab, whose fill already makes that edge.
    public static let separators = Tunable<Bool>.toggle(
        "tabs.separators", .tabs, "Tab separators",
        help: "A short line between tabs and before +, hidden beside the selected tab.",
        default: true, code: "TabTunables.separators")
    // @intent Lucas 2026-11-12 ("show the chevron on hover of the +"): on by default; off keeps the ⌄ shown.
    public static let chevronOnHover = Tunable<Bool>.toggle(
        "tabs.chevronOnHover", .tabs, "Pane type ⌄ only on hover",
        help: "The ⌄ after the tab bar's + shows only while the + or the ⌄ is under the pointer or its menu is open; it keeps its place.",
        default: true, code: "TabTunables.chevronOnHover")
    public static let pinnedDivider = Tunable<Bool>.toggle(
        "tabs.pinnedDivider", .tabs, "Pinned group divider",
        help: "A short line between the pinned tabs and the other tabs.",
        default: true, code: "TabTunables.pinnedDivider")
    public static let separatorOpacity = Tunable<CGFloat>.number(
        "tabs.separatorOpacity", .tabs, "Separator strength", help: "Opacity of the theme's separator tone in the line between tabs.",
        default: 0.2, range: 0...1, step: 0.02, unit: .fraction, code: "TabTunables.separatorOpacity")
    // @intent Lawrence 2026-10-20 ("the plus and dropdown and 3 dots [must] not appear unless hovered in
    // tabbar area") over Leo 2026-10-19 (muted at rest): hidden at rest, shown on tab bar hover. A value
    // above 0 shows them muted at rest again. Since the user's 2026-11-15 ask ("by default, all buttons
    // should be visible, not fade into view on hover"), this applies only in Minimal Mode
    // (``restingControlAlpha(crowded:minimal:in:)``); outside it the controls always show.
    public static let restingControlOpacity = Tunable<CGFloat>.number(
        "tabs.restingControlOpacity", .tabs, "Tab bar controls at rest",
        help: "In Minimal Mode, opacity of the tab bar's plus and pinned buttons while the pointer is elsewhere; hover shows them fully. 0 hides them. Outside Minimal Mode they always show.",
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

    /// The trailing controls' opacity at rest; `crowded`: the tabs fill the bar (``TabStripView/isCrowded``);
    /// `minimal`: Minimal Mode (``SidebarSectionsPreferences/hidesControlsUntilHover``). Outside it they always
    /// show (user 2026-11-15: "by default, all buttons should be visible, not fade into view on hover").
    public static func restingControlAlpha(crowded: Bool, minimal: Bool, in store: TunableStore = .shared) -> CGFloat {
        guard minimal else { return 1 }
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
    // @intent Leo 2026-11-07 asked whether the card should "morph together with the tab" ("goo ...
    // that water surface tension thing"): the three entrances side by side in the tab bar
    // playground's Hover Card page. The card fades in where it rests by default: grown out of its tab
    // it first drew a sliver over the tab's lower edge, then dropped and widened to its size, which
    // read as a bounce (Leo 2026-11-18, a recording of the pointer resting on a tab: "the hover
    // preview bounces for some reason"). Growing out of the tab stays an arm here.
    public static let hoverCardEntrance = Tunable<HoverCardEntrance>.choice(
        "tabs.hoverCardEntrance", .tabs, "Tab hover card entrance",
        help: "How a tab's hover card first shows: a fade, a fade and slide, or growing out of its tab.",
        default: .fade, code: "TabTunables.hoverCardEntrance")
    // @intent Leo 2026-11-18, "the hover preview bounces for some reason": the card slid and eased from tab
    // to tab (the glide, Lawrence 2026-11-15 msg 34360). It switches in place by default; the three moves
    // side by side in the tab bar playground's Hover Card page.
    public static let hoverCardRetarget = Tunable<HoverCardRetarget>.choice(
        "tabs.hoverCardRetarget", .tabs, "Tab hover card retarget",
        help: "How a tab's hover card moves to the next tab: switched in place, switched with its content crossfading, or gliding.",
        default: .jump, code: "TabTunables.hoverCardRetarget")
    /// Debug-only loading transition prototypes. Instant is the production
    /// default until one of the variants is selected for dogfood.
    public static let loadingAnimation = Tunable<TabLoadingAnimation>.choice(
        "tabs.loadingAnimation", .tabs, "Tab loading animation",
        help: "Prototype for a busy tab's indicator entering or leaving. Instant preserves the current behavior.",
        default: .instant, code: "TabTunables.loadingAnimation")
    // @intent Lawrence 2026-11-07 ("i still dont like these UIs", the tab bar's `+ ⌄ ⋮`): one look for the three
    // trailing controls. The split button (cmux classic's `+ ⌄`, Lucas 2026-11-11) is the default; the tab bar
    // playground's Trailing Buttons page compares them.
    public static let trailingButtons = Tunable<TabTrailingButtons>.choice(
        "tabs.trailingButtons", .tabs, "Tab bar buttons",
        help: "How the tab bar's plus, pane-type chevron and More look and show hover.",
        default: .split, code: "TabTunables.trailingButtons")
    /// The trailing controls' look in use: the tunable's, unless `appearance.toolbarButtonStyle` asks for bare glyphs
    /// (plain) or for the pane's pill (grouped, glass), where a fill per button would stack on the pill.
    @MainActor public static var effectiveTrailingButtons: TabTrailingButtons {
        DesignSettings.shared.toolbarButtonStyle == .standard ? trailingButtons.value : .glyphs
    }
    // @intent Leo 2026-10-22 (ask-a8b97f1201): one mark for a busy tab with unread output, not the dot and the
    // spinner side by side; the tab bar playground's Busy + Unread page compares the looks.
    public static let busyUnreadMark = Tunable<TabBusyUnreadMark>.choice(
        "tabs.busyUnreadMark", .tabs, "Busy and unread tab mark",
        help: "How a busy tab with unread output draws: one mark in the status slot, or the old dot and spinner side by side.",
        default: .spinner, code: "TabTunables.busyUnreadMark")
    // @intent Leo 2026-10-22 (ask-a8b97f1201): "the spacing is off"; the trailing mark mirrors the icon's inset. The
    // tab bar playground's Status Spacing page compares the placements.
    public static let statusMarkPlacement = Tunable<TabStatusMarkPlacement>.choice(
        "tabs.statusMarkPlacement", .tabs, "Tab status mark placement",
        help: "Where a tab's trailing spinner or unread dot sits: mirroring the icon, or in the close button's slot.",
        default: .mirrorIcon, code: "TabTunables.statusMarkPlacement")
    public static var all: [TunableDescriptor] {
        [compactTabWidth, scrollTabMinWidth, pinnedGroupGap, contentTrailingInset, closeButtonSize, closeGlyphSize, iconTitleSpacing, titleCloseSpacing,
         titleFadeWidth, badgeSize, closeMinContentsWidth, titleMinVisibleWidth, scrollFadeWidth,
         separatorHeight, groupChipPadding, groupUnderlineHeight, tearOffDistance, dragStartDistance].map(\.descriptor)
            + [separators.descriptor, pinnedDivider.descriptor, separatorOpacity.descriptor, restingControlOpacity.descriptor, crowdedControls.descriptor,
               crowdedControlOpacity.descriptor, groupJoinHysteresis.descriptor, autoscrollGain.descriptor,
               hoverPreviews.descriptor, hoverCardEntrance.descriptor, hoverCardRetarget.descriptor, loadingAnimation.descriptor, busyUnreadMark.descriptor, statusMarkPlacement.descriptor, trailingButtons.descriptor, chevronOnHover.descriptor] + VerticalTabTunables.all
            + GooTunables.all // the gooey tabs' knobs, a section per level (plans/cmux-next/gooey-tabs.md, "Knobs")
    }
}
