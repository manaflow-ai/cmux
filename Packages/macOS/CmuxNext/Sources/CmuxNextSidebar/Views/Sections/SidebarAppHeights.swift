import AppKit
import CmuxNextDesign

/// App section heights in the bands (kept off ``SidebarView``, whose type is at its size limit):
/// a section with a sidebar share (expanded All chats, Lawrence 2026-10-09: a fixed third of
/// the sidebar) takes that share of the sidebar's height; others their preferred height.
@MainActor
enum SidebarAppHeights {
    static func height(_ provider: any SidebarAppSectionProvider, _ contribution: String, width: CGFloat,
                       sidebarHeight: CGFloat) -> CGFloat {
        if let share = (provider.makeView(for: contribution) as? SidebarHoverRevealing)?.sidebarShare {
            return max(floor(sidebarHeight * share), Metrics.sidebarRowHeight)
        }
        return max(provider.preferredHeight(for: contribution, width: width), Metrics.sidebarRowHeight)
    }

    /// The band settings: a band holding a section with a sidebar share is not capped by
    /// `sidebar.bottomBandMaxShare` (the section's own share is the cap).
    static func preferences(below: SidebarRegionView) -> SidebarSectionsPreferences {
        var preferences = DesignSettings.shared.sidebarSections
        if below.appViews.values.contains(where: { ($0 as? SidebarHoverRevealing)?.sidebarShare != nil }) {
            preferences.bottomBandMaxShare = 1
        }
        return preferences
    }
}
