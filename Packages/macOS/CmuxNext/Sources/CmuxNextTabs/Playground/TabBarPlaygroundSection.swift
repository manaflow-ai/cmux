import Foundation

/// DEV and NIGHTLY (the Debug menu): the tab bar playground's pages (Lawrence msgs 19596, 19605, 19627, 20243, 21610).
enum TabBarPlaygroundSection: Int, CaseIterable {
    /// Many tabs in one pane: how a crowded tab shows its title (msg 19596).
    case crowdedTabs
    /// The tab bar's new-tab control, the "+ ⌄" (msg 19605).
    case newTabControl
    /// The tab bar's and the browser toolbar's trailing controls, the two ⋮ (msg 19627).
    case trailingControls
    /// The space and divider between the pinned tabs and the other tabs (msg 20243).
    case pinnedGap
    /// One radius for tabs and panes, nested corners concentric (Lawrence 2026-11-04).
    case cornerRadius
    /// A hovered tab's x in its status's slot (Leo 2026-11-05).
    case hoverClose
    /// A busy tab with unread output: one mark or the dot beside the spinner (Leo 2026-10-22).
    case busyUnread
    /// Where a tab's trailing spinner or dot sits beside its title (Leo 2026-10-22, "the spacing is off").
    case statusSpacing
    /// A tab's hover card: its width and how it first shows (Leo 2026-11-07).
    case hoverCard
    /// The flush corner's tab row under One Color and Subtle Tone: every corner (Leo 2026-11-12).
    case folderCorners
    /// How wide a tab grows in a roomy bar: three max widths (Leo 2026-11-24, "why half of the space taken up by blank!?").
    case tabMaxWidth

    var title: String {
        switch self {
        case .crowdedTabs: String(localized: "tabs.playground.section.crowded", defaultValue: "Crowded Tabs", bundle: .localizedModule)
        case .newTabControl: String(localized: "tabs.playground.section.newTab", defaultValue: "New Tab Control", bundle: .localizedModule)
        case .trailingControls: String(localized: "tabs.playground.section.trailing", defaultValue: "Trailing Controls", bundle: .localizedModule)
        case .pinnedGap: String(localized: "tabs.playground.section.pinnedGap", defaultValue: "Pinned Tabs Gap", bundle: .localizedModule)
        case .cornerRadius: String(localized: "tabs.playground.section.cornerRadius", defaultValue: "Corner Radius", bundle: .localizedModule)
        case .hoverClose: String(localized: "tabs.playground.section.hoverClose", defaultValue: "Hover Close", bundle: .localizedModule)
        case .busyUnread: String(localized: "tabs.playground.section.busyUnread", defaultValue: "Busy + Unread", bundle: .localizedModule)
        case .statusSpacing: String(localized: "tabs.playground.section.statusSpacing", defaultValue: "Status Spacing", bundle: .localizedModule)
        case .hoverCard: String(localized: "tabs.playground.section.hoverCard", defaultValue: "Hover Card", bundle: .localizedModule)
        case .folderCorners: String(localized: "tabs.playground.section.folderCorners", defaultValue: "Folder Corners", bundle: .localizedModule)
        case .tabMaxWidth: String(localized: "tabs.playground.section.tabMaxWidth", defaultValue: "Tab Max Width", bundle: .localizedModule)
        }
    }

    var variants: [TabBarPlaygroundVariant] {
        switch self {
        case .crowdedTabs: CrowdedTabsPlaygroundVariants().all
        case .newTabControl: NewTabControlPlaygroundVariants().all
        case .trailingControls: TrailingControlsPlaygroundVariants().all
        case .pinnedGap: PinnedGapPlaygroundVariants().all
        case .cornerRadius: ConcentricCornerPlaygroundVariants().all
        case .hoverClose: HoverClosePlaygroundVariants().all
        case .busyUnread: BusyUnreadPlaygroundVariants().all
        case .statusSpacing: StatusSpacingPlaygroundVariants().all
        case .hoverCard: HoverCardEntrancePlaygroundVariants().all
        case .folderCorners: FolderCornerPlaygroundVariants().all
        case .tabMaxWidth: TabMaxWidthPlaygroundVariants().all
        }
    }
}
