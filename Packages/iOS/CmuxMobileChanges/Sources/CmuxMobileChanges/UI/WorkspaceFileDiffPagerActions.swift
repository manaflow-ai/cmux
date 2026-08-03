#if canImport(UIKit)
public import UIKit
public typealias FileDiffInlinePreviewController = UIViewController
#else
public import Foundation
public typealias FileDiffInlinePreviewController = NSObject
#endif

/// Async loading, persistence, clipboard, and native preview actions for the diff pager.
public struct WorkspaceFileDiffPagerActions: Sendable {
    public let onLoad: @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation
    public let onLoadCurrentLines: @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile
    public let onPresentationAccess: @MainActor @Sendable (String) -> Void
    public let onPersistFontSize: @MainActor @Sendable (Double) -> Void
    public let onCopy: @MainActor @Sendable (String) -> Void
    public let inlinePreview: (@MainActor @Sendable (
        _ index: Int,
        _ revision: FileDiffPreviewRevision
    ) -> FileDiffInlinePreviewController)?

    public init(
        onLoad: @escaping @MainActor @Sendable (String, Bool, Int?) async throws -> FileDiffPresentation,
        onLoadCurrentLines: @escaping @MainActor @Sendable (String) async throws -> DiffExpansionCurrentFile,
        onPresentationAccess: @escaping @MainActor @Sendable (String) -> Void,
        onPersistFontSize: @escaping @MainActor @Sendable (Double) -> Void,
        onCopy: @escaping @MainActor @Sendable (String) -> Void,
        inlinePreview: (@MainActor @Sendable (
            _ index: Int,
            _ revision: FileDiffPreviewRevision
        ) -> FileDiffInlinePreviewController)? = nil
    ) {
        self.onLoad = onLoad
        self.onLoadCurrentLines = onLoadCurrentLines
        self.onPresentationAccess = onPresentationAccess
        self.onPersistFontSize = onPersistFontSize
        self.onCopy = onCopy
        self.inlinePreview = inlinePreview
    }
}
