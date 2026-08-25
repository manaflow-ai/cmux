/// Bounded min-heap used to evict the least-recently referenced artifact path.
struct ChatArtifactRecencyHeap {
    private var entries: [ChatArtifactRecencyHeapEntry] = []

    var count: Int { entries.count }

    mutating func insert(path: String, seq: Int) {
        entries.append(ChatArtifactRecencyHeapEntry(path: path, seq: seq))
        siftUp(from: entries.count - 1)
    }

    mutating func pop() -> ChatArtifactRecencyHeapEntry? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 { return entries.removeLast() }
        let result = entries[0]
        entries[0] = entries.removeLast()
        siftDown(from: 0)
        return result
    }

    mutating func compact(currentSequences: [String: Int]) {
        entries = currentSequences.map {
            ChatArtifactRecencyHeapEntry(path: $0.key, seq: $0.value)
        }
        guard entries.count > 1 else { return }
        for index in stride(from: entries.count / 2 - 1, through: 0, by: -1) {
            siftDown(from: index)
        }
    }

    private func precedes(
        _ lhs: ChatArtifactRecencyHeapEntry,
        _ rhs: ChatArtifactRecencyHeapEntry
    ) -> Bool {
        if lhs.seq != rhs.seq { return lhs.seq < rhs.seq }
        return lhs.path < rhs.path
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(entries[child], entries[parent]) else { return }
            entries.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            guard left < entries.count else { return }
            var candidate = left
            let right = left + 1
            if right < entries.count, precedes(entries[right], entries[left]) {
                candidate = right
            }
            guard precedes(entries[candidate], entries[parent]) else { return }
            entries.swapAt(parent, candidate)
            parent = candidate
        }
    }
}
