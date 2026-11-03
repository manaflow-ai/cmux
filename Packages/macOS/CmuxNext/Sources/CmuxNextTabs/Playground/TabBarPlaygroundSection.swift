import Foundation

/// DEV and NIGHTLY (the Debug menu): the tab bar playground's pages (Lawrence msgs 19596, 19605, 19627).
enum TabBarPlaygroundSection: Int, CaseIterable {
    /// Many tabs in one pane: how a crowded tab shows its title (msg 19596).
    case crowdedTabs
    /// The tab bar's new-tab control, the "+ ⌄" (msg 19605).
    case newTabControl
    /// The tab bar's and the browser toolbar's trailing controls, the two ⋮ (msg 19627).
    case trailingControls

    var title: String {
        switch self {
        case .crowdedTabs: String(localized: "tabs.playground.section.crowded", defaultValue: "Crowded Tabs", bundle: .module)
        case .newTabControl: String(localized: "tabs.playground.section.newTab", defaultValue: "New Tab Control", bundle: .module)
        case .trailingControls: String(localized: "tabs.playground.section.trailing", defaultValue: "Trailing Controls", bundle: .module)
        }
    }

    var variants: [TabBarPlaygroundVariant] {
        switch self {
        case .crowdedTabs: CrowdedTabsPlaygroundVariants().all
        case .newTabControl: NewTabControlPlaygroundVariants().all
        case .trailingControls: TrailingControlsPlaygroundVariants().all
        }
    }
}
