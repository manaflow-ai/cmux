actor CodeHighlightBatcher {
    private let highlighter: any CodeHighlighting
    private let capacity: Int
    private let batchSize: Int
    private var cache: [CodeHighlightCacheKey: CodeHighlightCacheEntry] = [:]
    private var accessCounter: UInt64 = 0

    init(highlighter: any CodeHighlighting, capacity: Int = 512, batchSize: Int = 24) {
        self.highlighter = highlighter
        self.capacity = max(1, capacity)
        self.batchSize = max(1, batchSize)
    }

    func highlights(for requests: [CodeHighlightRequest]) async -> [String: HighlightedCode] {
        var result: [String: HighlightedCode] = [:]
        for batchStart in stride(from: 0, to: requests.count, by: batchSize) {
            let batchEnd = min(requests.count, batchStart + batchSize)
            for request in requests[batchStart..<batchEnd] {
                let key = CodeHighlightCacheKey(
                    language: request.language,
                    line: request.line,
                    colorScheme: request.colorScheme
                )
                if let cached = cachedValue(for: key) {
                    result[request.id] = cached
                    continue
                }
                if let highlighted = await highlighter.highlight(
                    line: request.line,
                    language: request.language,
                    colorScheme: request.colorScheme
                ) {
                    insert(highlighted, for: key)
                    result[request.id] = highlighted
                }
            }
            await Task.yield()
        }
        return result
    }

    private func cachedValue(for key: CodeHighlightCacheKey) -> HighlightedCode? {
        guard var entry = cache[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        cache[key] = entry
        return entry.value
    }

    private func insert(_ value: HighlightedCode, for key: CodeHighlightCacheKey) {
        accessCounter &+= 1
        cache[key] = CodeHighlightCacheEntry(value: value, lastAccess: accessCounter)
        guard cache.count > capacity,
              let leastRecent = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else {
            return
        }
        cache.removeValue(forKey: leastRecent)
    }
}
