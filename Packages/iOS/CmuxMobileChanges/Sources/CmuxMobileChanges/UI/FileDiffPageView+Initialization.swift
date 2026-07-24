public import SwiftUI

extension FileDiffPageView {
    /// Creates one value-driven diff page.
    /// - Parameters:
    ///   - fileIndex: Stable index in the pager's changed-file snapshot.
    ///   - file: File metadata snapshot.
    ///   - initialPresentation: Mount-cache hit, when available.
    ///   - initialScrollRowID: Last visible row retained by the pager.
    ///   - fontSize: Current live diff font size.
    ///   - onFontSizeChanged: Live pinch callback.
    ///   - onScrollRowIDChanged: Lightweight scroll-position persistence callback.
    ///   - onPersistFontSize: End-of-pinch persistence callback.
    ///   - onLoad: Parsed-presentation loader with refresh and optional line-budget inputs.
    ///   - onLoadCurrentLines: Fetch-once loader for the current working-tree text.
    ///   - onCopy: Clipboard seam.
    ///   - inlinePreview: Optional binary-preview builder supplied by the composition layer.
    public init(
        fileIndex: Int,
        file: ChangedFileItem,
        initialPresentation: FileDiffPresentation?,
        initialScrollRowID: String? = nil,
        fontSize: Double,
        onFontSizeChanged: @escaping @MainActor @Sendable (Double) -> Void,
        onScrollRowIDChanged: @escaping @MainActor @Sendable (String?) -> Void = { _ in },
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onLoad: @escaping @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation,
        onLoadCurrentLines: @escaping @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)? = nil
    ) {
        self.fileIndex = fileIndex
        self.file = file
        self.fontSize = fontSize
        self.onFontSizeChanged = onFontSizeChanged
        self.onScrollRowIDChanged = onScrollRowIDChanged
        self.onPersistFontSize = onPersistFontSize
        self.onLoad = onLoad
        self.onLoadCurrentLines = onLoadCurrentLines
        self.onCopy = onCopy
        self.inlinePreview = inlinePreview
        loadState = initialPresentation.map(FileDiffLoadState.loaded) ?? .loading
        scrollRowID = initialScrollRowID
        previewRevision = FileDiffPreviewPolicy(kind: file.kind).defaultRevision
    }
}
