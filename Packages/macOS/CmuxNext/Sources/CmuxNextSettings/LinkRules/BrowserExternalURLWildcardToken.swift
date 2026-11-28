/// One token in a browser URL glob pattern.
nonisolated struct BrowserExternalURLWildcardToken: Sendable {
    /// `0` is `*`, `1` is `?`, and `2` is a literal character.
    let kind: UInt8
    let literal: String?
}
