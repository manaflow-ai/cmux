import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeEngine
public import CmuxNextSidebar
import Observation

/// The client-only items at the very top of a window's sidebar: the Channels entry after Home
/// while `home.channelsEnabled` is on (cx-frn2y), and the Chief's subagent rows under the Chief
/// item (`ChiefSidebar`), which draw only once the person adds that item. No Lanes item (Lawrence
/// 2026-10-20). What's New never shows here: after an update it is only the bottom-left "cmux
/// Updated!" card (Lawrence 2026-10-18). Agent chats on other machines never show here either: the
/// top band holds Home and what the person put there (Lawrence 2026-10-26); those chats are in the
/// Priority view and Home.
extension SidebarModel {
    /// Keeps `transientTopItems` current until cancelled.
    public func followTopItems(chief: ChiefSidebar = .shared) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        Task { [weak self] in
            for await (items, placed) in ObservationStream({ [weak self] in
                (Self.topItems(chief: chief), self?.layout.firstItem(with: .builtIn(.chief)) != nil)
            }) {
                guard let self else { return }
                if transientTopItems != items { transientTopItems = items }
                if chief.isPlaced != placed { chief.isPlaced = placed } // the layout is every window's, so any window's feed tells
            }
        }
    }

    /// The items the feed shows now. Read inside an observation scope, so a change re-yields.
    /// The Chief's subagent rows draw only under the Chief item, in the top band.
    public static func topItems(chief: ChiefSidebar = .shared) -> [SidebarTransientItem] {
        [DesignSettings.shared.homeChannelsEnabled && !HomeDock.classic ? SidebarTransientItem.channels : nil].compactMap(\.self)
            + chief.rows()
    }
}
