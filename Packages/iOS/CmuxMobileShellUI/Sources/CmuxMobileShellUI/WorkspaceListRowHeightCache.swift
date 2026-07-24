import CoreGraphics

/// A small LRU that also replaces superseded layout keys for each visible row identity.
struct WorkspaceListRowHeightCache<Key: Hashable> {
    let maximumEntryCount: Int
    private var heightsByKey: [Key: CGFloat] = [:]
    private var keysByRecency: [Key] = []
    private var keyByRowID: [String: Key] = [:]
    private var rowIDsByKey: [Key: Set<String>] = [:]

    init(maximumEntryCount: Int = 128) {
        precondition(maximumEntryCount > 0)
        self.maximumEntryCount = maximumEntryCount
    }

    var entryCount: Int {
        heightsByKey.count
    }

    mutating func height(for key: Key) -> CGFloat? {
        guard let height = heightsByKey[key] else { return nil }
        touch(key)
        return height
    }

    mutating func insert(_ height: CGFloat, for key: Key, rowID: String) {
        if let supersededKey = keyByRowID[rowID], supersededKey != key {
            rowIDsByKey[supersededKey]?.remove(rowID)
            if rowIDsByKey[supersededKey]?.isEmpty == true {
                rowIDsByKey.removeValue(forKey: supersededKey)
                heightsByKey.removeValue(forKey: supersededKey)
                keysByRecency.removeAll { $0 == supersededKey }
            }
        }
        keyByRowID[rowID] = key
        rowIDsByKey[key, default: []].insert(rowID)
        heightsByKey[key] = height
        touch(key)
        evictOverflow()
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        heightsByKey.removeAll(keepingCapacity: keepingCapacity)
        keysByRecency.removeAll(keepingCapacity: keepingCapacity)
        keyByRowID.removeAll(keepingCapacity: keepingCapacity)
        rowIDsByKey.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func retainRowIDs(_ retainedRowIDs: Set<String>) {
        let removedRowIDs = keyByRowID.keys.filter { !retainedRowIDs.contains($0) }
        for rowID in removedRowIDs {
            guard let key = keyByRowID.removeValue(forKey: rowID) else { continue }
            rowIDsByKey[key]?.remove(rowID)
            removeUnownedEntry(for: key)
        }
    }

    private mutating func touch(_ key: Key) {
        keysByRecency.removeAll { $0 == key }
        keysByRecency.append(key)
    }

    private mutating func evictOverflow() {
        while heightsByKey.count > maximumEntryCount {
            let evictedKey = keysByRecency.removeFirst()
            heightsByKey.removeValue(forKey: evictedKey)
            for rowID in rowIDsByKey.removeValue(forKey: evictedKey) ?? [] {
                if keyByRowID[rowID] == evictedKey {
                    keyByRowID.removeValue(forKey: rowID)
                }
            }
        }
    }

    private mutating func removeUnownedEntry(for key: Key) {
        guard rowIDsByKey[key]?.isEmpty != false else { return }
        rowIDsByKey.removeValue(forKey: key)
        heightsByKey.removeValue(forKey: key)
        keysByRecency.removeAll { $0 == key }
    }
}
