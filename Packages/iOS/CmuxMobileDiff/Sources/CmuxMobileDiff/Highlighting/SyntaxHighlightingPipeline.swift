internal import Foundation

/// Actor-isolated, bounded LRU pipeline for off-main per-row highlighting.
actor SyntaxHighlightingPipeline {
    private struct CacheKey: Hashable {
        let language: String
        let text: String
        let scheme: DiffHighlightScheme
    }

    private struct CacheEntry {
        let value: AttributedString
        var access: UInt64
    }

    private let light: any CodeHighlighting
    private let dark: any CodeHighlighting
    private let capacity: Int
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0

    /// Creates a highlighting pipeline with GitHub light and dark adapters.
    /// - Parameters:
    ///   - light: Light-scheme highlighter.
    ///   - dark: Dark-scheme highlighter.
    ///   - capacity: Maximum cached language, text, and scheme combinations.
    init(
        light: any CodeHighlighting = HighlighterSwiftCodeHighlighter(themeName: "github"),
        dark: any CodeHighlighting = HighlighterSwiftCodeHighlighter(themeName: "github-dark"),
        capacity: Int = 2_000
    ) {
        self.light = light
        self.dark = dark
        self.capacity = max(1, capacity)
    }

    /// Highlights requests in cancellable batches without occupying the main actor.
    /// - Parameters:
    ///   - requests: Row requests to highlight.
    ///   - scheme: Active color appearance.
    ///   - batchSize: Work items completed before yielding cooperatively.
    /// - Returns: Highlighted rows keyed by row identity.
    func highlights(
        for requests: [DiffHighlightRequest],
        scheme: DiffHighlightScheme,
        batchSize: Int = 24
    ) async throws -> [String: AttributedString] {
        var result: [String: AttributedString] = [:]
        let size = max(1, batchSize)
        for (index, request) in requests.enumerated() {
            try Task.checkCancellation()
            let key = CacheKey(language: request.language, text: request.text, scheme: scheme)
            if let cached = cachedValue(for: key) {
                result[request.rowID] = cached
            } else {
                let highlighter = scheme == .dark ? dark : light
                if let value = highlighter.highlight(request.text, language: request.language) {
                    insert(value, for: key)
                    result[request.rowID] = value
                }
            }
            if (index + 1).isMultiple(of: size) { await Task.yield() }
        }
        return result
    }

    private func cachedValue(for key: CacheKey) -> AttributedString? {
        guard var entry = cache[key] else { return nil }
        accessCounter &+= 1
        entry.access = accessCounter
        cache[key] = entry
        return entry.value
    }

    private func insert(_ value: AttributedString, for key: CacheKey) {
        accessCounter &+= 1
        cache[key] = CacheEntry(value: value, access: accessCounter)
        guard cache.count > capacity,
              let oldest = cache.min(by: { $0.value.access < $1.value.access })?.key else { return }
        cache.removeValue(forKey: oldest)
    }
}
