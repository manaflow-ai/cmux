import AppKit
import CmuxNextHome
public import CmuxNextSidebar

/// The Home list's Unread filter in the Sidebar States Playground (a939's filter, the user 2026-11-03, msg 20156):
/// the real `HomeSidebarView` with its filter off, then on (the lit toggle with its fill and the `HomeFilterChip`
/// "Unread ×" under search), then the empty filtered list (No Unread Chats over Show All).
///
/// It lives here, beside the other Home and sidebar glue, because the sidebar package never imports Home; the App
/// passes it to the playground (`SidebarActionSet`'s `playgroundSections`).
///
/// ```swift
/// SidebarActionSet(..., playgroundSections: { [HomeFilterPlaygroundSection().section()] })
/// ```
public struct HomeFilterPlaygroundSection {
    /// The Home list's width in each cell (the list's default width).
    var width: CGFloat = 320
    /// Air above and below the header band a look shows.
    var pad: CGFloat = 8

    /// Creates the section at the Home list's default width.
    public init() {}

    /// The playground section: the filter off, the filter on, the empty filtered list.
    public func section() -> SidebarStatesPlaygroundSection {
        SidebarStatesPlaygroundSection(title: String(localized: "home.filterPlayground.title", defaultValue: "Home filter", bundle: .module),
                                       looks: [])
    }
}
