extension FileSearchSnapshot {
    /// Keeps matches for each file contiguous while preserving first-seen file and match order.
    func groupingMatchesByFile() -> FileSearchSnapshot {
        guard results.count > 1 else { return self }

        var groupIndexByPath: [String: Int] = [:]
        var groups: [[FileSearchResult]] = []
        for result in results {
            if let index = groupIndexByPath[result.path] {
                groups[index].append(result)
            } else {
                groupIndexByPath[result.path] = groups.count
                groups.append([result])
            }
        }

        let groupedResults = groups.flatMap { $0 }
        guard groupedResults != results else { return self }
        var snapshot = self
        snapshot.results = groupedResults
        return snapshot
    }
}
