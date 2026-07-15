struct CodeHighlightCacheKey: Sendable, Hashable {
    let language: String?
    let line: String
    let colorScheme: DiffColorScheme
}
