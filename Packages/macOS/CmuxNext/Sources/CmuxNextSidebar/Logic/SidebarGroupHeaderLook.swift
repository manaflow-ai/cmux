public import CmuxNextDesign

/// How a sidebar group header draws (`sidebar.groupHeader`, cx-7yywz). cg-design-judge's sidebar
/// Thunderdome (2026-10-14, 108 blind bouts) found the solid pastel band the loudest thing in the
/// sidebar; the quieter looks keep the name and the group's color line. The band stays the
/// default until Leo and Lawrence pick one (Lawrence 2026-10-11 chose the band, cx-qno.22).
public nonisolated enum SidebarGroupHeaderStyle: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The solid rounded bar in the group's color (cx-qno.22).
    case band
    /// The name in primary ink, and the group's color only as the dot where its line starts.
    case line
    /// The name in the group's color, with the dot.
    case tinted
    /// A faint wash of the group's color behind the name in primary ink, with the dot.
    case wash

    public var tunableTitle: String {
        switch self {
        case .band: "Solid band"
        case .line: "Name and color line"
        case .tinted: "Tinted name and color line"
        case .wash: "Faint wash and color line"
        }
    }

    public static let tunable = Tunable<SidebarGroupHeaderStyle>.choice(
        "sidebar.groupHeader", .sidebar, "Group header",
        help: "How a group header draws: the solid band in the group's color, or quieter looks that keep the name and the group's color line.",
        default: .band, code: "SidebarGroupHeaderStyle.tunable")
}

/// Where sidebar group colors come from (`sidebar.groupColors`, cx-7yywz). Leo: group colors come
/// from the theme. Lawrence 2026-10-13 put the fixed palette back as the default (familiar group
/// colors first), so the theme's colors are a choice until they decide.
public nonisolated enum SidebarGroupPalette: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The fixed group palette (`GroupColor.rgb(_:dark:)`), the same in every theme.
    case fixed
    /// The theme's own color for each group color (its terminal palette, `GroupColor.themeRGB`).
    case theme

    public var tunableTitle: String {
        switch self {
        case .fixed: "Fixed palette"
        case .theme: "From the theme"
        }
    }

    public static let tunable = Tunable<SidebarGroupPalette>.choice(
        "sidebar.groupColors", .sidebar, "Group colors",
        help: "Where sidebar group colors come from: the fixed group palette, the same in every theme, or the theme's own colors.",
        default: .fixed, code: "SidebarGroupPalette.tunable")
}

/// Where a sidebar group's members' line sits against its header (`sidebar.groupLineLayout`, Debug). Leo
/// 2026-10-23, on the line: "THE FUCKING THHIN PURPLE LIINE IS THE GROUP!!!! THE POINT IS WHY DID IT GET SO OVFF
/// FUCKING CENTER ... PLUS THE SHAPING ON IT... WTF HAPPENED TO IT BEING PUSHED TO THE LEFT!?" Every layout keeps
/// the line where the header's rail reach puts it (`SidebarStyle.groupRailReach`) and draws Chrome's shape: 2 pt,
/// flat ends, the header bar's color. The members keep the ungrouped rows' left edge in every layout.
public nonisolated enum SidebarGroupLineLayout: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The line's left edge is the header bar's (Lawrence 2026-10-23), a cut below the bar.
    case edge
    /// Leo's join option ("option to just.. join the line would be cute", "it should all be lined up on the
    /// left"): as `edge`, with no cut, the bar's bottom-left corner square: bar and line read as one L.
    case joined
    /// Chrome's corner (Leo 2026-10-19: the line about 4 to 5 pt inside the header's left edge): the header reaches
    /// `SidebarStyle.groupLineCornerInset` further left, so the line runs out from under its rounded corner, a cut below.
    case inside

    public var tunableTitle: String {
        switch self {
        case .edge: "At the header's left edge"
        case .joined: "Joined to the header"
        case .inside: "Inside the header's corner"
        }
    }

    public static let tunable = Tunable<SidebarGroupLineLayout>.choice(
        "sidebar.groupLineLayout", .sidebar, "Group line",
        help: "Where a group's members' line sits: at the header's left edge, joined to the header as one shape, or inside the header's left corner.",
        default: .edge, code: "SidebarGroupLineLayout.tunable")
}
