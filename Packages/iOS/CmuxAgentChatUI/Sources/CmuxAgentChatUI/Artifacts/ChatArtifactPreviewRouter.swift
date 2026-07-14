import CmuxAgentChat
import Foundation
import UniformTypeIdentifiers

/// Resolves rich client preview routes from wire metadata and the filename.
struct ChatArtifactPreviewRouter: Sendable {
    /// Chooses the viewer route while preserving the four-case wire kind.
    ///
    /// Quick Look candidates still require a local
    /// `QLPreviewController.canPreview(_:)` check after download.
    func route(stat: ChatArtifactStat, path: String) -> ChatArtifactPreviewRoute {
        if stat.isDirectory {
            return .folder
        }
        if stat.kind == .image {
            return .image
        }

        let fileExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mimeType = stat.mimeType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if mimeType == "application/pdf" || fileExtension == "pdf" {
            return .pdf
        }

        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        if let type, type.conforms(to: .movie) || type.conforms(to: .audio) {
            return .media
        }
        if fileExtension == "md" || fileExtension == "markdown" {
            return .markdown
        }
        if stat.kind == .text {
            return .text
        }
        if let type, !type.isDynamic, type.conforms(to: .content) {
            return .quickLook
        }
        return .binary
    }
}
