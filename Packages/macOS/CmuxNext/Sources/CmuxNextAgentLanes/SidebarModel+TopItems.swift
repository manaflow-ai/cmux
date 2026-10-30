import CmuxNextCompat
import CmuxNextDesign
import CmuxNextHomeEngine
public import CmuxNextSidebar
public import CmuxNextWakeups

/// The client-only items at the very top of a window's sidebar: the Channels entry after Home
/// while `home.channelsEnabled` is on (cx-frn2y), and the Chief's subagent rows under the Chief
/// item (`ChiefSidebar`), which draw only once the person adds that item. No Lanes item (Lawrence
/// 2026-10-20). What's New never shows here: after an update it is only the bottom-left "cmux
/// Updated!" card (Lawrence 2026-10-18). Agent chats on other machines never show here either: the
/// top band holds Home and what the person put there (Lawrence 2026-10-26); those chats are in the
/// Priority view and Home.
extension SidebarModel {
    /// What ``followTopItems(on:chief:document:)`` follows: the top items and whether the sidebar places the Chief.
    public struct TopItems: Equatable {
        var items: [SidebarTransientItem]
        var chiefPlaced: Bool
    }

    /// Keeps `transientTopItems` current until the token is released or cancelled, on `mainWork` (the app's one
    /// main-thread scheduler). A service observation: it writes the sidebar model and `ChiefSidebar.isPlaced`,
    /// which the App Store card and the fold read with no sidebar on screen. `visible`: an agent's or a peer's change
    /// shows in the rows; a person's Add to Sidebar flushes before its frame. `document`: the sidebar document every
    /// window draws from.
    public func followTopItems(on mainWork: MainWorkScheduler, chief: ChiefSidebar = .shared,
                               document: @escaping @MainActor @Sendable () -> SidebarDocStore? = { SidebarDocStore.current })
        -> ServiceObservation<TopItems> {
        ServiceObservation(.visible, owner: "SidebarModel.topItems", on: mainWork) { [weak self] in
            // Placed in a band, or anywhere in the sidebar document (a group or a machine list): never this window's
            // rows, which its workspace membership filters, so every window's feed tells the same.
            TopItems(items: Self.topItems(chief: chief),
                     chiefPlaced: self.map { $0.layout.firstItem(with: .builtIn(.chief)) != nil } == true
                         || document()?.placesItem(with: .builtIn(.chief)) == true)
        } apply: { [weak self] next in
            guard let self else { return }
            if transientTopItems != next.items { transientTopItems = next.items }
            if chief.isPlaced != next.chiefPlaced { chief.isPlaced = next.chiefPlaced }
        }
    }

    /// The items the feed shows now. Read inside an observation scope, so a change re-yields.
    /// The Chief's subagent rows draw only under the Chief item, in the top band.
    public static func topItems(chief: ChiefSidebar = .shared) -> [SidebarTransientItem] {
        [DesignSettings.shared.homeChannelsEnabled && !HomeDock.classic ? SidebarTransientItem.channels : nil].compactMap(\.self)
            + chief.rows()
    }
}
