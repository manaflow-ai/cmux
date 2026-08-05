struct WordPathResolution: Sendable {
    /// The standardized path spelling selected from the clicked terminal text.
    let path: String
    /// The canonical filesystem target returned by the bounded probe.
    let resolvedPath: String
    let source: WordPathResolutionSource
    let rawToken: String
}
