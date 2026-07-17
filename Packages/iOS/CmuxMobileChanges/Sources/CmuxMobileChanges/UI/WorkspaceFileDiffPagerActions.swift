/// Async loading, persistence, and clipboard actions for the diff pager.
public struct WorkspaceFileDiffPagerActions: Sendable {
    /// Loads a parsed document, optionally bypassing the mount cache.
    public let onLoad: @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument
    /// Persists a clamped diff font size.
    public let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    /// Copies plain text through the mounting application's pasteboard seam.
    public let onCopy: @MainActor @Sendable (String) -> Void
    /// Opens one binary file revision in the mounting application's artifact viewer.
    public let onPreviewFile: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> Void)?

    /// Creates diff-pager actions.
    /// - Parameters:
    ///   - onLoad: Parsed-document loader with a force-refresh flag.
    ///   - onPersistFontSize: Font preference persistence callback.
    ///   - onCopy: Clipboard callback.
    ///   - onPreviewFile: Optional binary-file preview navigation callback.
    public init(
        onLoad: @escaping @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument,
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        onPreviewFile: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> Void)? = nil
    ) {
        self.onLoad = onLoad
        self.onPersistFontSize = onPersistFontSize
        self.onCopy = onCopy
        self.onPreviewFile = onPreviewFile
    }
}
