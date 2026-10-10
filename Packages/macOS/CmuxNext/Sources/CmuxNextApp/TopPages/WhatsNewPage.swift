import AppKit
import CmuxNextActions
import CmuxNextSidebar
import CmuxNextUpdater

/// What's New after an update (WHATS-NEW-AFTER-UPDATE W1): the React changelog page
/// (``ChangelogPageTab``), opened by the client-only sidebar item at the very top (shown until
/// the user opens it), the palette, the Help menu and `updates.whatsNew`. The native SwiftUI page
/// went with react-screens.md; the center (`WhatsNewCenter`) still tracks what is unseen.
@MainActor
enum WhatsNewPage {
    static let sidebarItemID = LayoutItemID(LayoutItemID.transientPrefix + "whats-new")

    /// Opens the changelog on this build (the span of the unseen notes) and marks every version up
    /// to this one seen. A run that may not change the view (automation) opens nothing and leaves
    /// the item.
    @discardableResult
    static func open(_ services: AppServices, in state: WindowState? = nil) -> Bool {
        guard ActionRunScope.viewChangeAllowed() else { return false }
        let center = services.updater.whatsNew
        // The span starts at the version seen before this update (read before `open` marks seen).
        let from = center.lastSeen.flatMap { seen in center.current.map { seen < $0 } == true ? seen : nil }
        center.open()
        return ChangelogPageTab.open(services, focus: true, from: from?.description, to: center.current?.description)
    }

    /// A click on a client-only sidebar item: the What's New item opens the page.
    static func activateClientItem(_ id: LayoutItemID, services: AppServices, in state: WindowState?) {
        if id == sidebarItemID { open(services, in: state) }
    }

    /// The sidebar item while it shows: after an update until opened.
    static func sidebarItem(center: WhatsNewCenter) -> SidebarTransientItem? {
        guard center.showsItem else { return nil }
        var info = SidebarItemInfo(title: WhatsNewPageStrings.title, symbol: "sparkles")
        info.unreadDot = true
        return SidebarTransientItem(id: sidebarItemID, info: info)
    }
}

nonisolated enum WhatsNewPageStrings {
    static var title: String { String(localized: "whatsNew.page.title", defaultValue: "What's New", table: "Handlers", bundle: .module) }
}
