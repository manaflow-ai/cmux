public import CmuxNextDesignTokens

/// How much of its color a group header's glass takes (`sidebar.groupGlass`). Leo 2026-11-05: "We can afford to put
/// glass here, so why the f*** do we not have glass for this? ... still keeping the colors, it's just, like, but just
/// make it glassier", "Why is it just one solid opaque block? Why does it not have any sort of rim at all?" The glass
/// itself is the shared `group` surface role (`SurfaceRole.group`: its veil over the sidebar's glass, `GlassRimView`'s
/// rim, the opaque Reduce Transparency fallback); this choice sets only how strongly the group's color, raised in chroma
/// (`GroupTint.glassRGB`), tints that veil. The palette is unchanged. Tab group chips, in the strip and the vertical
/// tab list, take the same glass (`GroupChipGlass`), so it lives here rather than in the sidebar.
public nonisolated enum SidebarGroupGlass: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// A clear tint of the color.
    case glass
    /// More of the color: the default, the one whose colors still read over a busy wallpaper in the gallery
    /// (`AANoColorGroupGalleryTests`; `glass` washed out on dark, `frost` read as no color).
    case vivid
    /// A light tint: mostly the role's frost.
    case frost
    /// The opaque bar before (cx-qno.22).
    case solid

    /// The share of the color over the role's veil, dark and light; 1 for the solid bar.
    public func tint(dark: Bool) -> Double {
        switch self {
        case .glass: dark ? 0.30 : 0.22
        case .vivid: dark ? 0.44 : 0.34
        case .frost: dark ? 0.16 : 0.12
        case .solid: 1
        }
    }

    public var tunableTitle: String {
        switch self {
        case .glass: "Tinted glass"
        case .vivid: "Vivid glass"
        case .frost: "Frosted glass"
        case .solid: "Solid bar"
        }
    }

    public static let tunable = Tunable<SidebarGroupGlass>.choice(
        "sidebar.groupGlass", .sidebar, "Group header glass",
        help: "How strongly a group header's glass takes its color: tinted, vivid or frosted glass with a rim, or the solid bar.",
        default: .vivid, code: "SidebarGroupGlass.tunable")
}
