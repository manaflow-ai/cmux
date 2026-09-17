struct MobileNotificationFeedAggregationCandidateHeap: Sendable {
    private var storage: [MobileNotificationFeedAggregationCandidate] = []

    mutating func insert(_ candidate: MobileNotificationFeedAggregationCandidate) {
        storage.append(candidate)
        siftUp(from: storage.count - 1)
    }

    mutating func pop() -> MobileNotificationFeedAggregationCandidate? {
        guard !storage.isEmpty else { return nil }
        guard storage.count > 1 else { return storage.removeLast() }
        let candidate = storage[0]
        storage[0] = storage.removeLast()
        siftDown(from: 0)
        return candidate
    }

    private mutating func siftUp(from startIndex: Int) {
        var child = startIndex
        while child > 0 {
            let parent = (child - 1) / 2
            guard candidatePrecedes(storage[child], storage[parent]) else { return }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from startIndex: Int) {
        var parent = startIndex
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var candidate = parent
            if left < storage.count, candidatePrecedes(storage[left], storage[candidate]) {
                candidate = left
            }
            if right < storage.count, candidatePrecedes(storage[right], storage[candidate]) {
                candidate = right
            }
            guard candidate != parent else { return }
            storage.swapAt(parent, candidate)
            parent = candidate
        }
    }

    private func candidatePrecedes(
        _ lhs: MobileNotificationFeedAggregationCandidate,
        _ rhs: MobileNotificationFeedAggregationCandidate
    ) -> Bool {
        if !mobileNotificationFeedItemPrecedes(lhs.item, rhs.item),
           !mobileNotificationFeedItemPrecedes(rhs.item, lhs.item) {
            if lhs.sourceIndex != rhs.sourceIndex {
                return lhs.sourceIndex < rhs.sourceIndex
            }
            return lhs.itemIndex < rhs.itemIndex
        }
        return mobileNotificationFeedItemPrecedes(lhs.item, rhs.item)
    }
}
