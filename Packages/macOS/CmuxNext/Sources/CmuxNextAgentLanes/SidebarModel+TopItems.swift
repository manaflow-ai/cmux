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
/// Priority view and Home. A look's nav block (`sidebar.nav`) draws first, above Home (`SidebarTransientItem.nav`).
/// The one exception is the Labs Hosts section (`labs.hostsSidebar`, off by default): feature modules add its
/// transient rows through the `additional` source, and those rows never enter the durable sidebar document.
extension SidebarModel {
    /// Keeps `transientTopItems` current until cancelled. `document`: the app's own sidebar document, which every
    /// window of that app draws from.
    public func followTopItems(chief: ChiefSidebar = .shared,
                               document: @escaping @MainActor @Sendable () -> SidebarDocStore?,
                               additional: @escaping @MainActor @Sendable () -> [SidebarTransientItem] = { [] }) -> Task<Void, Never> {
        // task-owner: the bridge (cancelled in teardown); event-driven (Observation)
        Task { [weak self] in
            for await items in ObservationStream({ [weak self] in
                // Placed in a band, or anywhere in the sidebar document (a group or a machine list): never this window's
                // rows, which its workspace membership filters, so every window's feed tells the same.
                (Self.topItems(chief: chief) + additional(), self.map { $0.layout.firstItem(with: .builtIn(.chief)) != nil } == true
                    || document()?.placesItem(with: .builtIn(.chief)) == true,
                 self.map { model in SidebarTransientItem.chiefAnchors.contains { model.layout.firstItem(with: $0) != nil } } == true)
            }) {
                guard let self else { return }
                if transientTopItems != items.0 { transientTopItems = items.0 }
                if chief.isPlaced != items.1 { chief.isPlaced = items.1 }
                if chief.showsThread != items.2 { chief.showsThread = items.2 }
            }
        }
    }

    /// The items the feed shows now. Read inside an observation scope, so a change re-yields.
    /// The Chief is one line (Lawrence 2026-11-26: "ideally Chief is just a single line"): its subagents
    /// never draw as rows under it; the Chief pane's Subagents menu (`ChiefSidebar.allSubagents`) lists them.
    public static func topItems(chief: ChiefSidebar = .shared) -> [SidebarTransientItem] {
        SidebarTransientItem.nav(DesignSettings.shared.sidebarSections.nav)
            + [DesignSettings.shared.homeChannelsEnabled && !HomeDock.classic ? SidebarTransientItem.channels : nil].compactMap(\.self)
    }
}
