struct SidebarLogRingBuffer {
    private var storage: [SidebarLogEntry?]
    private var head = 0
    private(set) var count = 0
    private(set) var limit: Int

    init(limit: Int) {
        let normalizedLimit = max(1, min(500, limit))
        self.limit = normalizedLimit
        self.storage = Array(repeating: nil, count: normalizedLimit)
    }

    mutating func replaceAll(_ entries: [SidebarLogEntry], limit: Int) {
        self = SidebarLogRingBuffer(limit: limit)
        for entry in entries.suffix(self.limit) {
            append(entry)
        }
    }

    mutating func append(_ entry: SidebarLogEntry) {
        guard !storage.isEmpty else { return }
        let index = (head + count) % storage.count
        if count == storage.count {
            storage[head] = entry
            head = (head + 1) % storage.count
        } else {
            storage[index] = entry
            count += 1
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: limit)
        head = 0
        count = 0
    }

    func entries() -> [SidebarLogEntry] {
        guard count > 0 else { return [] }
        return (0..<count).compactMap { offset in
            storage[(head + offset) % storage.count]
        }
    }
}
