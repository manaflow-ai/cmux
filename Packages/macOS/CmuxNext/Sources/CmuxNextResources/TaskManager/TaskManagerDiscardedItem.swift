import Foundation

/// An item Memory Saver discarded (a hibernated page, a parked terminal surface). It has no process
/// now, so it is not a row of the process table: the Task Manager lists it apart, with the memory it
/// held in its last sample before the discard.
///
/// Chrome keeps the same number for a discarded tab: `PreDiscardResourceUsage`
/// (chrome/browser/performance_manager/public/user_tuning/user_performance_tuning_manager.h) records
/// the page's estimated footprint when it is discarded, and the tab hover card and the Memory Saver
/// chip show it as the memory saved.
public struct TaskManagerDiscardedItem: Sendable, Equatable, Identifiable {
    /// The item's key (a tab id), the same key its live tab had in ``TabResourceSources/tabID``.
    public var id: String
    public var title: String
    /// The item's memory in its last sample before the discard; nil when the discarder had no sample.
    /// ``TaskManagerModel`` then takes its own last sample of the item, if it saw one.
    public var savedBytes: UInt64?

    public init(id: String, title: String, savedBytes: UInt64? = nil) {
        self.id = id
        self.title = title
        self.savedBytes = savedBytes
    }
}
