/// Deduplicated FIFO of visible worktree status probes and their earliest start times.
nonisolated struct WorktreeSidebarStatusQueue {
    private var paths: [String?] = []
    private var headIndex = 0
    private var indexByPath: [String: Int] = [:]
    private var eligibleAtByPath: [String: ContinuousClock.Instant] = [:]

    var firstPath: String? {
        guard headIndex < paths.count else { return nil }
        return paths[headIndex...].lazy.compactMap { $0 }.first
    }
    var isEmpty: Bool { indexByPath.isEmpty }

    mutating func enqueue(
        path: String,
        eligibleAt: ContinuousClock.Instant
    ) -> Bool {
        guard indexByPath[path] == nil else { return false }
        indexByPath[path] = paths.count
        paths.append(path)
        eligibleAtByPath[path] = eligibleAt
        return true
    }

    func eligibleAt(for path: String) -> ContinuousClock.Instant? {
        eligibleAtByPath[path]
    }

    @discardableResult
    mutating func popFirst() -> String? {
        advanceHead()
        guard headIndex < paths.count, let path = paths[headIndex] else {
            resetStorageIfEmpty()
            return nil
        }
        paths[headIndex] = nil
        headIndex += 1
        indexByPath[path] = nil
        eligibleAtByPath[path] = nil
        advanceHead()
        compactIfNeeded()
        return path
    }

    @discardableResult
    mutating func remove(path: String) -> Bool {
        guard let index = indexByPath.removeValue(forKey: path) else { return false }
        paths[index] = nil
        eligibleAtByPath[path] = nil
        if index == headIndex {
            advanceHead()
        }
        compactIfNeeded()
        return true
    }

    mutating func removeAll() {
        paths.removeAll()
        headIndex = 0
        indexByPath.removeAll()
        eligibleAtByPath.removeAll()
    }

    private mutating func advanceHead() {
        while headIndex < paths.count, paths[headIndex] == nil {
            headIndex += 1
        }
    }

    private mutating func compactIfNeeded() {
        guard headIndex > 64, headIndex * 2 >= paths.count else {
            resetStorageIfEmpty()
            return
        }
        paths = Array(paths[headIndex...])
        headIndex = 0
        indexByPath = Dictionary(uniqueKeysWithValues: paths.indices.compactMap { index in
            paths[index].map { ($0, index) }
        })
    }

    private mutating func resetStorageIfEmpty() {
        guard indexByPath.isEmpty else { return }
        paths.removeAll(keepingCapacity: true)
        headIndex = 0
    }
}
