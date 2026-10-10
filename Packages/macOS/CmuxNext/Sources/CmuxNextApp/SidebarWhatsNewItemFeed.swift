import CmuxNextCompat
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The client-only What's New item at the very top of a window's sidebar
/// (WHATS-NEW-AFTER-UPDATE W1): after an update until the user opens the
/// changelog page.
@MainActor
enum SidebarWhatsNewItemFeed {
    static func start(model: SidebarModel, center: WhatsNewCenter) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        Task {
            for await item in ObservationStream({ WhatsNewPage.sidebarItem(center: center) }) {
                let items = item.map { [$0] } ?? []
                if model.transientTopItems != items { model.transientTopItems = items }
            }
        }
    }
}
