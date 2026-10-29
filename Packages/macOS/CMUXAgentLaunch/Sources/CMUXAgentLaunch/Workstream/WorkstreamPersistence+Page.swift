import Foundation

extension WorkstreamPersistence.Page {
    /// The last journal mutation for each UUID, in journal order.
    /// Keep raw page cursors unchanged even when duplicate rows are omitted.
    var latestItems: [WorkstreamItem] {
        var seen = Set<UUID>()
        return Array(items.reversed().filter { seen.insert($0.id).inserted }.reversed())
    }
}
