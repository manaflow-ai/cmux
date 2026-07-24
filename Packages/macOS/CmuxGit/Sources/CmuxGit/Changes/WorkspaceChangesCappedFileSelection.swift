/// Retains a deterministic, path-sorted prefix without storing every candidate.
struct WorkspaceChangesCappedFileSelection: Sendable {
    let maximumCount: Int
    private(set) var files: [WorkspaceChangedFile] = []

    init(maximumCount: Int) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
        files.reserveCapacity(maximumCount)
    }

    /// Keeps the lexicographically smallest paths, matching the prior sorted-prefix policy.
    mutating func consider(_ file: WorkspaceChangedFile) {
        let insertionIndex = insertionIndex(for: file.path)
        if insertionIndex < files.count, files[insertionIndex].path == file.path {
            files[insertionIndex] = file
            return
        }
        guard files.count < maximumCount || insertionIndex < maximumCount else {
            return
        }
        files.insert(file, at: insertionIndex)
        if files.count > maximumCount {
            files.removeLast()
        }
    }

    private func insertionIndex(for path: String) -> Int {
        var lowerBound = 0
        var upperBound = files.count
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if files[midpoint].path < path {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        return lowerBound
    }
}
