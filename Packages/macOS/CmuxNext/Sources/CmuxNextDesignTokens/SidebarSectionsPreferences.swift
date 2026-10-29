/// The sidebar section settings in cmux.json (`sidebar.sectionLook`,
/// `sidebar.topBandMaxShare`, `sidebar.bottomBandMaxShare`,
/// `sidebar.pinnedBandsScroll`, `sidebar.showWorkspaceTabs` and
/// `sidebar.workspaceRow.*`; plans/cmux-next/sidebar-sections.md 7).
/// `sidebar.showChats` lists every chat (All chats) on the New Tab page, where All chats moved
/// from the sidebar (cx-n0i9); on by default (cx-xub5).
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

/// `sidebar.style` (Lawrence 2026-10-21: "a minimal custom design for the sidebar that is
/// thinner and takes up virtually 0 horizontal space"; plans/cmux-next/minimal-sidebar.md).
public nonisolated enum SidebarLayoutStyle: String, Hashable, Sendable, CaseIterable {
    /// The sidebar at the user's width, beside the content (the default).
    case standard
    /// A few-point rail of workspace ticks beside the content; pointing at it
    /// opens the full sidebar over the content, which never moves.
    case rail
}

/// `sidebar.groupBy`: how the Projects list buckets its loose workspaces
/// (Leo 2026-10-06).
public nonisolated enum SidebarGroupBy: String, Hashable, Sendable, CaseIterable {
    case none
    /// A header per folder: the front tab's working directory.
    case folder
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
    /// Whether the workspace list expands each workspace into its tab rows. On by default
    /// (Lawrence 2026-10-27: "show everything by default"); off hides every workspace's tabs.
    public var showWorkspaceTabs: Bool
    /// `sidebar.groupByComputer`: one workspace section per computer, each
    /// under its header. Off (the default) shows one list of workspaces with
    /// no computer headers; a workspace of another computer names it on its
    /// second line.
    public var groupsByComputer = false
    /// `workspaces.autoName` (hq#1957): a workspace the user never named
    /// takes its front tab's name (a page's, a chat's, a terminal's). On by default.
    public var autoNamesWorkspaces = true
    /// What each workspace row shows (`sidebar.workspaceRow.*`): by default
    /// the name, the user's icon and the unread/attention mark only
    /// (SIDEBAR-ROWS-MINIMAL-AND-CUSTOMIZABLE).
    public var workspaceRow = WorkspaceRowPreferences.defaults
    /// The workspace list (Projects) shows; its header's menu hides it (`sidebar.showProjects`).
    public var showProjects = true
    /// The Projects menu's Group By (`sidebar.groupBy`).
    public var groupBy: SidebarGroupBy = .none
    /// Show All Chats on New Tab: the New Tab page's Threads and Console styles list every
    /// chat on this device; off, the recent chats only (Lawrence 2026-10-09: on by default). The
    /// key keeps its `sidebar.` name from when All chats was a sidebar section (cx-n0i9).
    public var showChats = true
    /// The bottom band's pieces (cx-wab7m): each hides from its own right-click menu and comes
    /// back from the band's (`sidebar.showSpaces`: the spaces dots; `sidebar.showProfileControl`:
    /// the profile button).
    public var showSpaces = true
    public var showProfileControl = true
    /// `sidebar.showSearchButton`: the footer's Search button after the profile avatar
    /// (plans/cmux-next/sidebar-search.md). On by default; off hides the button only.
    public var showSearchButton = true
    /// `sidebar.noFade`: the whole left sidebar shows with no edge fade, and the bottom profile and
    /// search bar hides (Lawrence 2026-10-26). Off by default: the edges fade and the bar shows.
    public var noFade = false
    /// `sidebar.controlsOnHover` (Show Sidebar Controls Only on Hover, Lawrence 2026-10-27): the sidebar's New Workspace
    /// button, spaces strip, profile control and Search button show only while the pointer is over
    /// the sidebar. Off by default: they always show.
    public var controlsOnHover = false
    /// Minimal mode (`sidebar.minimal`, cx-w1r5; Lawrence 2026-10-09: "some
    /// people like minimal mode"): workspace rows draw only their icon, name,
    /// unread mark and attention state (no second line, no counts or badges,
    /// no tab rows), and section headers become thin lines (the `lines` look).
    public var minimal = false
    /// `sidebar.detailedStatusIcons`: a workspace row's badge draws each state apart (working,
    /// waiting for input, error, done, as agents and OSC 7501 programs report them). Off by default:
    /// the row says Working (one spinner) or Ready (the blue dot) only (Lawrence 2026-10-18).
    public var detailedStatusIcons = false
    /// `sidebar.showTimestamps`: workspace rows show when they last changed (a time today, else an
    /// age such as `3d`) on the name's line. Off by default (Lawrence 2026-10-19: "By default in the
    /// sidebar, we should never show timestamps"); the hover card keeps its times either way.
    public var showTimestamps = false
    /// `sidebar.showColors`: the sidebar draws workspace and group colors. Off draws none (a
    /// workspace's swatch goes, its symbol or emoji stays; a group draws as one with no color)
    /// and keeps every stored color (Lawrence 2026-10-22: "need to be able to remove all
    /// workspace colors"). On by default.
    public var showColors = true
    /// `sidebar.showLocalMachine`: with more than one machine listed, this Mac's workspace rows
    /// carry its machine mark too. Off by default (Leo 2026-10-20): only another machine's rows
    /// are marked, since that is the news; this Mac is where a row runs unless it says otherwise.
    public var showLocalMachine = false
    /// `sidebar.groupHeader.memberCount`: a collapsed group's header shows how many workspaces it
    /// holds after its name. Off by default (Lawrence 2026-10-20: "All we care about is the
    /// loading"); the header shows only its loading spinner.
    public var groupHeaderMemberCount = false
    /// `sidebar.groupHeader.unreadCount`: a collapsed group's header shows its members' unread
    /// total on the right. Off by default, as ``groupHeaderMemberCount``.
    public var groupHeaderUnreadCount = false
    /// Compact (the default), comfortable or expanded workspace rows
    /// (`sidebar.density`); minimal mode wins over expanded content.
    public var density: SidebarDensity = .compact
    /// Pinned bands that hide until the pointer is over the sidebar (R54).
    /// Off by default: a fresh profile's sidebar is pinned, its Settings and
    /// account band always shown; hover-reveal is opt-in (Leo 2026-10-11).
    public var minimalMode: SidebarMinimalMode = .off
    /// Cmd-1…9 and Cmd-Ctrl-[ / ] (`sidebar.numbering`, `sidebar.cmd9`,
    /// `sidebar.stepping`, `sidebar.steppingWraps`).
    public var navigation = SidebarNavigationSettings.defaults
    /// The "Did you know" tip card above the footer (`sidebar.cards.tips`,
    /// BOTTOM-LEFT-CARDS K1). The update card always shows when an update
    /// is staged.
    public var showsTips = true
    /// The Priority view (`sidebar.priorityView.enabled`): an optional App Store item, off by
    /// default. On, a bell in the sidebar's titlebar row shows or hides it.
    public var priorityViewEnabled = false
    /// `sidebar.priorityView.shown`: the bell's state, whether the installed Priority view shows
    /// at the top of the sidebar. Off, the sidebar is unchanged.
    public var priorityViewShown = true
    /// `sidebar.sessionTree` (Claude desktop's Code tab): a workspace started by another
    /// workspace's agent lists under it on a thin line, rows carry their pull requests, and the
    /// first rows their Command-number keycaps. Off by default: it changes the list's look.
    public var sessionTree = false
    /// `sidebar.style`: the standard sidebar (default) or the thin rail.
    public var style: SidebarLayoutStyle = .standard

    public init(look: String = "quiet", topBandMaxShare: Double = 1.0 / 3.0, bottomBandMaxShare: Double = 0.25,
                pinnedBandsScroll: Bool = true, showWorkspaceTabs: Bool = true) {
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
