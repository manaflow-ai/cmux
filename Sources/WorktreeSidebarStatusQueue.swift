/// Deduplicated FIFO of visible worktree status probes and their earliest start times.
struct WorktreeSidebarStatusQueue {
    private var paths: [String] = []
    private var queuedPaths: Set<String> = []
    private var eligibleAtByPath: [String: ContinuousClock.Instant] = [:]

    var firstPath: String? { paths.first }
    var isEmpty: Bool { paths.isEmpty }

    mutating func enqueue(
        path: String,
        eligibleAt: ContinuousClock.Instant
    ) -> Bool {
        guard queuedPaths.insert(path).inserted else { return false }
        paths.append(path)
        eligibleAtByPath[path] = eligibleAt
        return true
    }

    func eligibleAt(for path: String) -> ContinuousClock.Instant? {
        eligibleAtByPath[path]
    }

    @discardableResult
    mutating func popFirst() -> String? {
        guard !paths.isEmpty else { return nil }
        let path = paths.removeFirst()
        queuedPaths.remove(path)
        eligibleAtByPath[path] = nil
        return path
    }

    @discardableResult
    mutating func remove(path: String) -> Bool {
        guard queuedPaths.remove(path) != nil else { return false }
        paths.removeAll { $0 == path }
        eligibleAtByPath[path] = nil
        return true
    }

    mutating func removeAll() {
        paths.removeAll()
        queuedPaths.removeAll()
        eligibleAtByPath.removeAll()
    }
}
