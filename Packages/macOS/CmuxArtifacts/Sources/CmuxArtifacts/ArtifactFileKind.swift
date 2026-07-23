public import Foundation

/// Coarse preview and capture classification for an artifact file.
public enum ArtifactFileKind: String, Codable, CaseIterable, Sendable {
    /// A bitmap or vector image.
    case image
    /// A video or screen recording.
    case video
    /// Markdown source rendered by cmux's markdown viewer.
    case markdown
    /// An HTML document opened in a browser pane.
    case html
    /// A unified diff or patch.
    case patch
    /// A small searchable text or structured-text file.
    case text
    /// A file outside the default automatic-capture allowlist.
    case other

    /// Classifies a file from its filename extension.
    ///
    /// - Parameter url: File URL to classify.
    /// - Returns: Coarse artifact kind.
    public static func classify(_ url: URL) -> ArtifactFileKind {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg":
            return .image
        case "mp4", "mov", "m4v", "webm":
            return .video
        case "md", "markdown", "mdown", "mkd":
            return .markdown
        case "html", "htm":
            return .html
        case "diff", "patch":
            return .patch
        case "txt", "log", "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "xml":
            return .text
        default:
            return .other
        }
    }

    /// Whether content search may decode the file as UTF-8 text.
    public var isTextSearchable: Bool {
        switch self {
        case .markdown, .html, .patch, .text:
            return true
        case .image, .video, .other:
            return false
        }
    }
}
