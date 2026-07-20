public import SwiftUI

/// Async loading, persistence, clipboard, and preview actions for the diff pager.
public struct WorkspaceFileDiffPagerActions: Sendable {
    /// Loads a parsed document, optionally bypassing the mount cache.
    public let onLoad: @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument
    /// Persists a clamped diff font size.
    public let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    /// Copies plain text through the mounting application's pasteboard seam.
    public let onCopy: @MainActor @Sendable (String) -> Void
    /// Builds an inline binary preview in the mounting application's artifact viewer.
    public let inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)?

    /// Creates diff-pager actions.
    /// - Parameters:
    ///   - onLoad: Parsed-document loader with a force-refresh flag.
    ///   - onPersistFontSize: Font preference persistence callback.
    ///   - onCopy: Clipboard callback.
    ///   - inlinePreview: Optional binary-preview builder supplied by the composition layer.
    public init(
        onLoad: @escaping @MainActor @Sendable (String, Bool) async throws -> FileDiffDocument,
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        inlinePreview: (@MainActor @Sendable (_ index: Int, _ revision: FileDiffPreviewRevision) -> AnyView)? = nil
    ) {
        self.onLoad = onLoad
        self.onPersistFontSize = onPersistFontSize
        self.onCopy = onCopy
        self.inlinePreview = inlinePreview
    }
}
