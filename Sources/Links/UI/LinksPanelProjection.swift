struct LinksPanelProjection {
    var allEntriesCount: Int
    var filteredEntries: [WorkspaceCapturedLink]
    var hosts: [String]
    var sources: [LinksPanelSourceOption]
    var selectedSourceTitle: String?
    var dayBuckets: [LinksPanelDayBucket]
}
