struct HunkHeader {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    init?(rawLine: String) {
        guard rawLine.hasPrefix("@@ ") else { return nil }
        let parts = rawLine.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "@@",
              let oldRange = UnifiedDiffHunkRange(raw: parts[1], prefix: "-"),
              let newRange = UnifiedDiffHunkRange(raw: parts[2], prefix: "+") else {
            return nil
        }
        oldStart = oldRange.start
        oldCount = oldRange.count
        newStart = newRange.start
        newCount = newRange.count
    }
}
