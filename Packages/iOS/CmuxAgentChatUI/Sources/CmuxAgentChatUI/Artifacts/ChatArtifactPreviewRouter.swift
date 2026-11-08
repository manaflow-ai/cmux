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
        let mimeType = Self.normalizedMIMEType(stat.mimeType)
        if mimeType == "application/pdf" || fileExtension == "pdf" {
            return .pdf
        }

        let type = fileExtension.isEmpty ? nil : UTType(filenameExtension: fileExtension)
        if isMedia(type) || isMedia(mimeType.flatMap { UTType(mimeType: $0) }) {
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

    /// Preferred filename extension for a wire MIME type, used to type
    /// extensionless temporary files for preview frameworks.
    func preferredExtension(forMIMEType rawMIMEType: String?) -> String? {
        guard let mimeType = Self.normalizedMIMEType(rawMIMEType),
              let type = UTType(mimeType: mimeType) else {
            return nil
        }
        return type.preferredFilenameExtension
    }

    private func isMedia(_ type: UTType?) -> Bool {
        guard let type else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }

    private static func normalizedMIMEType(_ rawValue: String?) -> String? {
        guard let normalized = rawValue?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty else {
            return nil
        }
        return normalized
    }
}
