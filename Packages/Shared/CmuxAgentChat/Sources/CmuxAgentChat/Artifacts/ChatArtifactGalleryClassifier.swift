import Foundation
import UniformTypeIdentifiers

/// Classifies gallery artifacts into the dedicated sheet filter buckets.
public struct ChatArtifactGalleryClassifier: Sendable {
    private let logExtensions: Set<String> = ["log", "out"]
    private let documentExtensions: Set<String> = [
        "doc", "docx", "key", "md", "markdown", "mdown", "mkd", "numbers",
        "odp", "ods", "odt", "pages", "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx",
    ]

    /// Creates an artifact classifier.
    public init() {}

    /// Returns the artifact's dedicated filter bucket, if it has one.
    ///
    /// Image and directory kinds take precedence over filename extensions.
    /// Artifacts returning `nil` remain visible under ``ChatArtifactGalleryFilter/all``.
    ///
    /// - Parameters:
    ///   - kind: Preview kind assigned by the artifact host.
    ///   - path: Artifact path whose extension supplements the preview kind.
    /// - Returns: A dedicated filter bucket, or `nil` for All-only artifacts.
    public func filter(
        for kind: ChatArtifactKind,
        path: String
    ) -> ChatArtifactGalleryFilter? {
        switch kind {
        case .image:
            return .images
        case .directory:
            return .folders
        case .text, .binary:
            break
        }

        let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard !pathExtension.isEmpty else { return nil }
        if let type = UTType(filenameExtension: pathExtension),
           type.conforms(to: .sourceCode) {
            return .code
        }
        if logExtensions.contains(pathExtension) {
            return .logs
        }
        if documentExtensions.contains(pathExtension) {
            return .docs
        }
        return nil
    }

    /// Returns the artifact's dedicated filter bucket, if it has one.
    ///
    /// - Parameter item: Gallery item to classify.
    /// - Returns: A dedicated filter bucket, or `nil` for All-only artifacts.
    public func filter(for item: ChatArtifactGalleryItem) -> ChatArtifactGalleryFilter? {
        filter(for: item.kind, path: item.path)
    }

    /// Returns the shared SF Symbol for an artifact gallery row.
    ///
    /// PDF, Office, Markdown, plain-text, and otherwise generic files share
    /// one document glyph. Only images, source code, logs, and folders use
    /// distinct presentation.
    ///
    /// - Parameters:
    ///   - kind: Preview kind assigned by the artifact host.
    ///   - path: Artifact path whose extension supplements the preview kind.
    /// - Returns: SF Symbol name for list and grid placeholders.
    public func systemImageName(
        for kind: ChatArtifactKind,
        path: String
    ) -> String {
        switch kind {
        case .image:
            return "photo"
        case .directory:
            return "folder"
        case .text, .binary:
            break
        }
        switch filter(for: kind, path: path) {
        case .code:
            return "chevron.left.forwardslash.chevron.right"
        case .logs:
            return "text.alignleft"
        case .images:
            return "photo"
        case .folders:
            return "folder"
        case .docs, .all, nil:
            return "doc.text"
        }
    }
}
