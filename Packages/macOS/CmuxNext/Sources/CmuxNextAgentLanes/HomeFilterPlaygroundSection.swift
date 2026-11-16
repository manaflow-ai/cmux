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
        SidebarStatesPlaygroundSection(title: String(localized: "home.filterPlayground.title", defaultValue: "Home filter", bundle: .module), looks: [
            SidebarStatesPlaygroundLook(title: String(localized: "home.filterPlayground.off", defaultValue: "Unread filter off", bundle: .module)) { root in
                let (home, parts) = stage(in: root, unread: false)
                return header(home, parts, in: root)
            },
            SidebarStatesPlaygroundLook(title: String(localized: "home.filterPlayground.on", defaultValue: "Unread filter on (lit button, Unread × chip)",
                                                      bundle: .module)) { root in
                let (home, parts) = stage(in: root, unread: true)
                return header(home, parts, in: root)
            },
            SidebarStatesPlaygroundLook(title: String(localized: "home.filterPlayground.empty", defaultValue: "No Unread Chats, Show All",
                                                      bundle: .module)) { root in
                let (home, parts) = stage(in: root, unread: true)
                return root.convert(parts.emptyList, from: home).intersection(root.bounds)
            },
        ])
    }

    /// A Home list with no chats at the top-left of `root`, its Unread filter `unread`, laid out; its filter's parts.
    @MainActor private func stage(in root: NSView, unread: Bool) -> (HomeSidebarView, HomeSidebarView.FilterParts) {
        let height = min(root.bounds.height, 480)
        let home = HomeSidebarView(frame: NSRect(x: 0, y: root.isFlipped ? 0 : root.bounds.height - height, width: width, height: height))
        root.addSubview(home)
        home.unreadOnly = unread
        return (home, home.filterParts())
    }

    /// The header band a look shows, in `root`: the list's width, from the search row (the toggle's row) to under the
    /// chip while it shows.
    @MainActor private func header(_ home: HomeSidebarView, _ parts: HomeSidebarView.FilterParts, in root: NSView) -> NSRect {
        let band = parts.chip.map { parts.toggle.union($0) } ?? parts.toggle
        let rect = root.convert(CGRect(x: 0, y: band.minY, width: home.bounds.width, height: band.height), from: home)
        return rect.insetBy(dx: 0, dy: -pad).intersection(root.bounds)
    }
}
