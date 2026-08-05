struct WordPathResolution: Sendable {
    /// The standardized path spelling selected from the clicked terminal text.
    let path: String
    /// The canonical filesystem target returned by the bounded probe.
    let resolvedPath: String
    /// Whether the canonical target is a readable regular file. Directories
    /// remain valid editor targets but must not enter file-only Browser routes.
    let isReadableRegularFile: Bool
    let source: WordPathResolutionSource
    let rawToken: String
}
