import Foundation

/// DEV and NIGHTLY (Debug menu > Sidebar States Playground, Lawrence msg 19746: "show me all the possible sidebar
/// states, and i will critique their sizings"): one row state of the sidebar, drawn by the real row view of
/// ``SidebarStatesPlaygroundFixture`` at every density, text size and appearance.
///
/// The order is the playground's row order. Every case has its row in the fixture
/// (``SidebarStatesPlaygroundFixture/ref(for:)``); `SidebarStatesPlaygroundCatalogTests` renders them and checks each.
enum SidebarStatesPlaygroundState: String, CaseIterable, Sendable {
    /// A workspace row with nothing to say.
    case idle
    /// An agent works: the working spinner.
    case busy
    /// Something new to read: the blue unread dot.
    case unread
    /// The agent needs you (a plain waiting report): the orange mark.
    case needsYou
    /// A failure: the red warning mark.
    case error
    /// A program asks a question through OSC 7501 (the detailed needs-input mark).
    case needsInput
    /// A runaway agent chat: the usage warning triangle.
    case usageWarning
    /// A pinned workspace: its row in the Pinned band (`SidebarItemRowView`).
    case pinned
    /// The active workspace: the selection fill.
    case selected
    /// Under the pointer: the hover fill and the hover controls.
    case hovered
    /// The inline rename editor over the title.
    case renaming
    /// Archived: the dimmed row under the open Archive section.
    case archived
    /// A workspace on an SSH machine, in that machine's section.
    case remote
    /// An open group's header.
    case groupExpanded
    /// A collapsed group's header with its members' roll-up (working, needs you, unread).
    case groupCollapsed
    /// Home, the first row of the top band.
    case home
    /// An open group with no members, hovered: its header's + (New Workspace in Group).
    case emptyGroup
    /// A colored workspace at rest under `workspaceColors.indicatorStyle` `leftRail`: its leading bar (Lawrence
    /// msg 19775). The selected and hovered rows are colored too, so they show the bar in those states.
    case accentBar
    /// An open group's member: its group's rail down the leading edge.
    case groupRail
    /// Favicon rows (the slot the favicon style variants, `sidebar.faviconStyle`, draw in): a browser workspace with a
    /// dark one-color favicon (GitHub-like).
    case faviconMono
    /// A browser workspace with a colorful favicon (Google-like).
    case faviconColorful
    /// A browser workspace whose page has no favicon: the placeholder globe (``WorkspaceIcon/pagePlaceholder``).
    case faviconMissing
    /// The pinned row with its real hover card (`WorkspaceHoverCardView`) beside it, as a hover shows it (Lawrence
    /// 2026-11-03: "make sure size of the pinned summary thing reflect size of ui compactness i chose"). The sheet
    /// draws it in its own section below the grid, since the card is wider than a sidebar.
    case pinnedHoverCard

    /// The rows each favicon styles sheet shows (`SidebarStatesPlaygroundColumn.favicons(_:)`).
    static let favicons: [SidebarStatesPlaygroundState] = [.faviconMono, .faviconColorful, .faviconMissing]

    /// The row's caption in the playground.
    var title: String {
        switch self {
        case .idle: String(localized: "sidebar.statesPlayground.state.idle", defaultValue: "Idle", bundle: .module)
        case .busy: String(localized: "sidebar.statesPlayground.state.busy", defaultValue: "Busy (spinner)", bundle: .module)
        case .unread: String(localized: "sidebar.statesPlayground.state.unread", defaultValue: "Unread (blue dot)", bundle: .module)
        case .needsYou: String(localized: "sidebar.statesPlayground.state.needsYou", defaultValue: "Needs you (orange)", bundle: .module)
        case .error: String(localized: "sidebar.statesPlayground.state.error", defaultValue: "Error (red warning)", bundle: .module)
        case .needsInput:
            String(localized: "sidebar.statesPlayground.state.needsInput", defaultValue: "Needs input (question)", bundle: .module)
        case .usageWarning:
            String(localized: "sidebar.statesPlayground.state.usageWarning", defaultValue: "Usage warning", bundle: .module)
        case .pinned: String(localized: "sidebar.statesPlayground.state.pinned", defaultValue: "Pinned", bundle: .module)
        case .selected: String(localized: "sidebar.statesPlayground.state.selected", defaultValue: "Selected", bundle: .module)
        case .hovered: String(localized: "sidebar.statesPlayground.state.hovered", defaultValue: "Hovered", bundle: .module)
        case .renaming: String(localized: "sidebar.statesPlayground.state.renaming", defaultValue: "Renaming", bundle: .module)
        case .archived: String(localized: "sidebar.statesPlayground.state.archived", defaultValue: "Archived", bundle: .module)
        case .remote: String(localized: "sidebar.statesPlayground.state.remote", defaultValue: "Remote (SSH)", bundle: .module)
        case .groupExpanded:
            String(localized: "sidebar.statesPlayground.state.groupExpanded", defaultValue: "Group header, open", bundle: .module)
        case .groupCollapsed:
            String(localized: "sidebar.statesPlayground.state.groupCollapsed", defaultValue: "Group header, collapsed", bundle: .module)
        case .home: String(localized: "sidebar.statesPlayground.state.home", defaultValue: "Home", bundle: .module)
        case .emptyGroup: String(localized: "sidebar.statesPlayground.state.emptyGroup", defaultValue: "Empty group (+)", bundle: .module)
        case .accentBar: String(localized: "sidebar.statesPlayground.state.accentBar", defaultValue: "Left accent bar", bundle: .module)
        case .groupRail: String(localized: "sidebar.statesPlayground.state.groupRail", defaultValue: "Group rail", bundle: .module)
        case .faviconMono:
            String(localized: "sidebar.statesPlayground.state.faviconMono", defaultValue: "Favicon, dark mono", bundle: .module)
        case .faviconColorful:
            String(localized: "sidebar.statesPlayground.state.faviconColorful", defaultValue: "Favicon, colorful", bundle: .module)
        case .faviconMissing:
            String(localized: "sidebar.statesPlayground.state.faviconPlaceholder", defaultValue: "No favicon, globe placeholder", bundle: .module)
        case .pinnedHoverCard:
            String(localized: "sidebar.statesPlayground.state.pinnedHoverCard", defaultValue: "Pinned row and its hover card", bundle: .module)
        }
    }
}
