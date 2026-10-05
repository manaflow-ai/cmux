/// The sidebar section settings in cmux.json (`sidebar.sectionLook`,
/// `sidebar.topBandMaxShare`, `sidebar.bottomBandMaxShare`,
/// `sidebar.pinnedBandsScroll` and `sidebar.showWorkspaceTabs`;
/// plans/cmux-next/sidebar-sections.md 7).
/// `sidebar.minimalMode`: which pinned bands hide until the pointer is over
/// the sidebar (R54).
public nonisolated enum SidebarMinimalMode: String, Hashable, Sendable, CaseIterable {
    case off
    /// The bottom band: the Settings and account row.
    case bottom
    case top
    case both

    public var hidesTop: Bool { self == .top || self == .both }
    public var hidesBottom: Bool { self == .bottom || self == .both }
}

/// How the optional window dock presents sidebar destinations.
public nonisolated enum SidebarDockMode: String, Hashable, Sendable, CaseIterable {
    /// The dock is absent and content uses the full window height.
    case off
    /// The dock keeps an icon-height strip reserved at the bottom.
    case reserved
    /// The dock floats over the bottom edge while the pointer is over it.
    case overlay
}

public nonisolated struct SidebarSectionsPreferences: Hashable, Sendable {
    /// A `SectionsLookVariant` raw value (CmuxNextSidebar); unknown = quiet.
    public var look: String
    /// Share of the sidebar height the band above the list takes before it
    /// scrolls inside.
    public var topBandMaxShare: Double
    /// Share for the band below the list.
    public var bottomBandMaxShare: Double
    /// False: the bands never scroll; the list shrinks instead (to a
    /// minimum of three rows).
    public var pinnedBandsScroll: Bool
    /// Whether the workspace list expands each workspace into its tab rows.
    public var showWorkspaceTabs: Bool
    /// Pinned bands that hide until the pointer is over the sidebar (R54).
    /// R100: the Settings/account band shows only while the pointer is over the sidebar.
    public var minimalMode: SidebarMinimalMode = .bottom
    /// The bottom dock exploration. Off is intentionally the default.
    public var dockMode: SidebarDockMode

    public init(look: String = "quiet", topBandMaxShare: Double = 1.0 / 3.0, bottomBandMaxShare: Double = 0.25,
                pinnedBandsScroll: Bool = true, showWorkspaceTabs: Bool = false,
                dockMode: SidebarDockMode = .off) {
        self.look = look
        self.topBandMaxShare = topBandMaxShare
        self.bottomBandMaxShare = bottomBandMaxShare
        self.pinnedBandsScroll = pinnedBandsScroll
        self.showWorkspaceTabs = showWorkspaceTabs
        self.dockMode = dockMode
    }

    public static let defaults = SidebarSectionsPreferences()
    public static let shareRange: ClosedRange<Double> = 0.1...0.9
    /// The two shares together leave at least this much for the list.
    public static let maxShareSum = 0.8
}
