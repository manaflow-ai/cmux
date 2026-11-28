import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The client-only What's New item at the very top of a window's sidebar
/// (WHATS-NEW-AFTER-UPDATE W1): after an update until the user opens the
/// page, and while the window shows the page.
@MainActor
enum SidebarWhatsNewItemFeed {
    static func start(model: SidebarModel, center: WhatsNewCenter, state: WindowState) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        Task { [weak state] in
            for await item in Observations({ WhatsNewPage.sidebarItem(center: center, shownPage: state?.page) }) {
                let items = item.map { [$0] } ?? []
                if model.transientTopItems != items { model.transientTopItems = items }
            }
        }
    }
}
