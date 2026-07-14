import Foundation
import UniformTypeIdentifiers

/// Classifies gallery artifacts into the dedicated sheet filter buckets.
public struct ChatArtifactGalleryClassifier: Sendable {
    private let logExtensions: Set<String> = ["log", "out", "txt"]
    private let documentExtensions: Set<String> = [
        "doc", "docx", "key", "md", "markdown", "mdown", "mkd", "numbers",
        "odp", "ods", "odt", "pages", "pdf", "ppt", "pptx", "rtf", "xls", "xlsx",
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
}
