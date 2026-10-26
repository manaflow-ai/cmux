import Foundation

/// An item Memory Saver discarded (a hibernated page). It has no process now, so it is not a row of
/// the process table: the Task Manager lists it apart, with the memory it held when it was discarded.
///
/// Chrome keeps the same number for a discarded tab: `PreDiscardResourceUsage`
/// (chrome/browser/performance_manager/public/user_tuning/user_performance_tuning_manager.h) records
/// the page's estimated footprint when it is discarded, and the tab hover card and the Memory Saver
/// chip show it as the memory saved.
public struct TaskManagerDiscardedItem: Sendable, Equatable, Identifiable {
    /// The item's key (a tab id), the same key its live tab had in ``TabResourceSources/tabID``.
    public var id: String
    public var title: String
    /// The memory the discarder recorded when it discarded the item; nil when it had no measurement then.
    public var savedBytes: UInt64?

    public init(id: String, title: String, savedBytes: UInt64? = nil) {
        self.id = id
        self.title = title
        self.savedBytes = savedBytes
    }

    /// The discarded items among `tabs`, in tab order: each tab `isDiscarded` says is, with its
    /// title and the bytes `savedBytes` recorded for it.
    public static func list(in tabs: [TabResourceSources], isDiscarded: (String) -> Bool,
                            savedBytes: [String: UInt64]) -> [TaskManagerDiscardedItem] {
        var seen = Set<String>()
        return tabs.compactMap { tab in
            guard isDiscarded(tab.tabID), seen.insert(tab.tabID).inserted else { return nil }
            return TaskManagerDiscardedItem(id: tab.tabID, title: tab.title, savedBytes: savedBytes[tab.tabID])
        }
    }
}
