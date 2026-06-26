/// A resolved file path for a command-click word, with provenance.
///
/// Produced by ``TerminalPathResolver`` when a word under the cursor (from
/// QuickLook extraction or a visible-grid snapshot) resolves to an existing
/// file-system path. `rawToken` is the unresolved text the path came from,
/// retained for runtime debug payloads.
public struct WordPathResolution: Sendable {
    /// The resolved, existing file-system path.
    public let path: String
    /// Which terminal-text source produced this resolution.
    public let source: WordPathResolutionSource
    /// The raw token the resolution was derived from.
    public let rawToken: String

    /// Creates a resolution.
    ///
    /// - Parameters:
    ///   - path: The resolved, existing file-system path.
    ///   - source: Which terminal-text source produced the resolution.
    ///   - rawToken: The raw token the resolution was derived from.
    public init(path: String, source: WordPathResolutionSource, rawToken: String) {
        self.path = path
        self.source = source
        self.rawToken = rawToken
    }
}
