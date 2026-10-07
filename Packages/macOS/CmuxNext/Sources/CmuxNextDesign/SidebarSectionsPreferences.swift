/// The sidebar section settings in cmux.json (`sidebar.sectionLook`,
/// `sidebar.topBandMaxShare`, `sidebar.bottomBandMaxShare`,
/// `sidebar.pinnedBandsScroll`, `sidebar.showWorkspaceTabs` and
/// `sidebar.workspaceRow.*`; plans/cmux-next/sidebar-sections.md 7).
/// `sidebar.showChats` controls the optional device-wide Chats section.
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
    /// What each workspace row shows (`sidebar.workspaceRow.*`): by default
    /// the name, the user's icon and the unread/attention mark only
    /// (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// The workspace list (Projects) shows; its header's menu hides it (`sidebar.showProjects`).
    public var showProjects = true
    /// Whether the device-wide Chats section is shown in the sidebar; its
    /// header's Hide Section turns it off.
    public var showChats = false
    /// Pinned bands that hide until the pointer is over the sidebar (R54).
    /// R100: the Settings/account band shows only while the pointer is over the sidebar.
    public var minimalMode: SidebarMinimalMode = .bottom
    /// Cmd-1…9 and Cmd-Ctrl-[ / ] (`sidebar.numbering`, `sidebar.cmd9`,
    /// `sidebar.stepping`, `sidebar.steppingWraps`).
    public var navigation = SidebarNavigationSettings.defaults
    /// The "Did you know" tip card above the footer (`sidebar.cards.tips`,
    /// BOTTOM-LEFT-CARDS K1). The update card always shows when an update
    /// is staged.
    public var showsTips = true

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
