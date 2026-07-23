public import SwiftUI

/// Async loading, persistence, clipboard, and preview actions for the diff pager.
public struct WorkspaceFileDiffPagerActions: Sendable {
    /// Loads a parsed document with refresh and optional progressive-budget inputs.
    public let onLoad: @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffDocument
    /// Loads current working-tree lines for hidden-context expansion.
    public let onLoadCurrentLines: @MainActor @Sendable (String) async throws -> [String]
    /// Persists a clamped diff font size.
    public let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    /// Copies plain text through the mounting application's pasteboard seam.
    public let onCopy: @MainActor @Sendable (String) -> Void
    /// Builds an inline binary preview in the mounting application's artifact viewer.
    public let inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)?

    /// Creates diff-pager actions.
    /// - Parameters:
    ///   - onLoad: Parsed-document loader with refresh and optional line-budget inputs.
    ///   - onLoadCurrentLines: Fetch-once current working-tree text loader.
    ///   - onPersistFontSize: Font preference persistence callback.
    ///   - onCopy: Clipboard callback.
    ///   - inlinePreview: Optional binary-preview builder supplied by the composition layer.
    public init(
        onLoad: @escaping @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffDocument,
        onLoadCurrentLines: @escaping @MainActor @Sendable (String) async throws -> [String],
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)? = nil
    ) {
        self.onLoad = onLoad
        self.onLoadCurrentLines = onLoadCurrentLines
        self.onPersistFontSize = onPersistFontSize
        self.onCopy = onCopy
        self.inlinePreview = inlinePreview
    }
}
