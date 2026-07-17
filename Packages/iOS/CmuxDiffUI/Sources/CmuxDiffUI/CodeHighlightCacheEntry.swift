struct CodeHighlightCacheEntry: Sendable {
    let value: HighlightedCode
    var lastAccess: UInt64
}
