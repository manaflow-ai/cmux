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

    /// Creates a classification from a file's filename extension.
    ///
    /// - Parameter fileURL: File URL to classify.
    public init(fileURL: URL) {
        switch fileURL.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg":
            self = .image
        case "mp4", "mov", "m4v", "webm":
            self = .video
        case "md", "markdown", "mdown", "mkd":
            self = .markdown
        case "html", "htm":
            self = .html
        case "diff", "patch":
            self = .patch
        case "txt", "log", "json", "jsonl", "yaml", "yml", "toml", "csv", "tsv", "xml":
            self = .text
        default:
            self = .other
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
