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
    /// Off by default: the footer's avatar and gear always draw (Leo
    /// 2026-10-06); `.bottom` is R100's hover-only footer, opt-in.
    public var minimalMode: SidebarMinimalMode = .off
    /// Cmd-1…9 and Cmd-Ctrl-[ / ] (`sidebar.numbering`, `sidebar.cmd9`,
    /// `sidebar.stepping`, `sidebar.steppingWraps`).
    public var navigation = SidebarNavigationSettings.defaults

    public init(look: String = "quiet", topBandMaxShare: Double = 1.0 / 3.0, bottomBandMaxShare: Double = 0.25,
                pinnedBandsScroll: Bool = true, showWorkspaceTabs: Bool = false) {
        self.look = look
        self.topBandMaxShare = topBandMaxShare
        self.bottomBandMaxShare = bottomBandMaxShare
        self.pinnedBandsScroll = pinnedBandsScroll
        self.showWorkspaceTabs = showWorkspaceTabs
    }

    public static let defaults = SidebarSectionsPreferences()
    public static let shareRange: ClosedRange<Double> = 0.1...0.9
    /// The two shares together leave at least this much for the list.
    public static let maxShareSum = 0.8
}
