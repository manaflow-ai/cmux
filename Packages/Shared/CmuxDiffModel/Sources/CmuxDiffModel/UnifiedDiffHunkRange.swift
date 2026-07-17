struct UnifiedDiffHunkRange {
    let start: Int
    let count: Int

    init?<Raw: StringProtocol>(raw: Raw, prefix: Character) {
        guard raw.first == prefix else { return nil }
        let body = raw.dropFirst()
        let pieces = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let startRaw = pieces.first, let start = Int(startRaw) else { return nil }
        let count = pieces.count == 2 ? Int(pieces[1]) : 1
        guard let count,
              start >= 0,
              count >= 0,
              start <= Int.max - UnifiedDiffParser.maximumLineCountPerHunk else {
            return nil
        }
        if count > 0 {
            let (_, overflow) = start.addingReportingOverflow(count - 1)
            guard !overflow else { return nil }
        }
        self.start = start
        self.count = count
    }
}
