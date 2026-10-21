import CmuxNextAgentActivity
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeEngine
public import CmuxNextSidebar
import Observation

/// The client-only items at the very top of a window's sidebar: Lanes (cx-v9k2f)
/// while a lane shows (Leo 2026-10-20: no longer only with Labs preview features
/// on, it is the one view of what every agent is doing), the Channels entry after Home while
/// `home.channelsEnabled` is on (cx-frn2y), and the Chief's subagent rows under the Chief
/// item (`ChiefSidebar`). What's New never shows here: after an
/// update it is only the bottom-left "cmux Updated!" card (Lawrence 2026-10-18).
extension SidebarModel {
    /// Keeps `transientTopItems` current until cancelled.
    public func followTopItems(lanes: AgentLaneStore = .shared, chief: ChiefSidebar = .shared) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        Task { [weak self] in
            for await items in ObservationStream({ Self.topItems(lanes: lanes, chief: chief) }) {
                guard let self else { return }
                if transientTopItems != items { transientTopItems = items }
            }
        }
    }

    /// The items the feed shows now. Read inside an observation scope, so a change re-yields.
    /// The Chief's subagent rows draw only under the Chief item, in the top band.
    public static func topItems(lanes: AgentLaneStore, chief: ChiefSidebar = .shared) -> [SidebarTransientItem] {
        [SidebarTransientItem.lanes(lanes),
         DesignSettings.shared.homeChannelsEnabled && !HomeDock.classic ? SidebarTransientItem.channels : nil].compactMap(\.self)
            + chief.rows()
    }
}
