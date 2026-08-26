import Foundation

struct LinksPanelProjection {
    var allEntriesCount: Int
    var filteredEntries: [WorkspaceCapturedLink]
    var hosts: [String]
    var sources: [LinksPanelSourceOption]
    var selectedSourceTitle: String?
    var dayBuckets: [LinksPanelDayBucket]
    var locationsByEntryID: [UUID: LinksPanelEntryLocation]

    static let empty = LinksPanelProjection(
        allEntriesCount: 0,
        filteredEntries: [],
        hosts: [],
        sources: [],
        selectedSourceTitle: nil,
        dayBuckets: [],
        locationsByEntryID: [:]
    )

    mutating func updateTitleSnapshot(_ entry: WorkspaceCapturedLink) {
        guard let location = locationsByEntryID[entry.id],
              filteredEntries.indices.contains(location.filteredIndex),
              dayBuckets.indices.contains(location.bucketIndex),
              dayBuckets[location.bucketIndex].entries.indices.contains(location.entryIndex) else {
            return
        }
        filteredEntries[location.filteredIndex] = entry
        dayBuckets[location.bucketIndex].entries[location.entryIndex] = entry
    }
}
