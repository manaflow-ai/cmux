import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The client-only items at the very top of a window's sidebar: What's New
/// (WHATS-NEW-AFTER-UPDATE W1) after an update until the user opens the
/// changelog page, and Lanes (cx-v9k2f) while Labs preview features are on;
/// and the Channels entry after Home while `home.channelsEnabled` is on (cx-frn2y).
@MainActor
enum SidebarWhatsNewItemFeed {
    static func start(model: SidebarModel, center: WhatsNewCenter, settings: SettingsController? = nil,
                      lanes: AgentLaneStore = .shared) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        return Task {
            for await items in ObservationStream({ () -> [SidebarTransientItem] in
                [WhatsNewPage.sidebarItem(center: center),
                 settings?.snapshot.previewFeatures == true ? SidebarTransientItem.lanes(lanes) : nil,
                 DesignSettings.shared.homeChannelsEnabled && !HomeDock.classic ? SidebarTransientItem.channels : nil].compactMap(\.self)
            }) {
                if model.transientTopItems != items { model.transientTopItems = items }
            }
        }
    }
}
