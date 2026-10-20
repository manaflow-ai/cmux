import CmuxNextAgentActivity
import CmuxNextAgentLanes
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeEngine
import CmuxNextSettings
import CmuxNextSidebar
import CmuxNextUpdater
import Observation

/// The client-only items at the very top of a window's sidebar: Lanes (cx-v9k2f)
/// while Labs preview features are on, and the Channels entry after Home while
/// `home.channelsEnabled` is on (cx-frn2y). What's New never shows here: after an
/// update it is only the bottom-left "cmux Updated!" card (Lawrence 2026-10-18).
@MainActor
enum SidebarWhatsNewItemFeed {
    static func start(model: SidebarModel, settings: SettingsController? = nil,
                      lanes: AgentLaneStore = .shared) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        return Task {
            for await items in ObservationStream({ Self.items(settings: settings, lanes: lanes) }) {
                if model.transientTopItems != items { model.transientTopItems = items }
            }
        }
    }

    /// The items the feed shows now. Read inside an observation scope, so a change re-yields.
    static func items(settings: SettingsController?, lanes: AgentLaneStore) -> [SidebarTransientItem] {
        [settings?.snapshot.previewFeatures == true ? SidebarTransientItem.lanes(lanes) : nil,
         DesignSettings.shared.homeChannelsEnabled && !HomeDock.classic ? SidebarTransientItem.channels : nil].compactMap(\.self)
    }
}
