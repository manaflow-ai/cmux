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
