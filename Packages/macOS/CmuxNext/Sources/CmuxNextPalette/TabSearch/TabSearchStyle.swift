public import CmuxNextDesign

/// Search Tabs layout prototypes (`palette.tabSearchStyle` in Debug
/// Settings, DEV and NIGHTLY only). Release builds always use `recent`.
public nonisolated enum TabSearchStyle: String, Sendable, CaseIterable, TunableChoice {
    /// One list of open tabs, most recently used first, then Recently
    /// Closed. Each row names its workspace and directory or site.
    case recent
    /// Open tabs grouped under their window and workspace in layout order,
    /// then Recently Closed.
    case grouped
    /// The recent list with titles only and the site or folder name: more
    /// rows on screen, five closed tabs before typing.
    case compact

    public var tunableTitle: String {
        switch self {
        case .recent: "Recent (one list, most recent first)"
        case .grouped: "Grouped (by window and workspace)"
        case .compact: "Compact (titles, site or folder)"
        }
    }
}

/// Debug Settings declarations of the palette.
public nonisolated enum PaletteTunables {
    public static let tabSearchStyle = Tunable<TabSearchStyle>.choice(
        "palette.tabSearchStyle", .palette, "Search Tabs layout",
        help: "Prototype layout of Search Tabs (Cmd-Shift-A). Applies the next time it opens.",
        default: .recent, code: "PaletteTunables.tabSearchStyle")

    public static var all: [TunableDescriptor] { [tabSearchStyle.descriptor] + scopeDescriptors }
}
