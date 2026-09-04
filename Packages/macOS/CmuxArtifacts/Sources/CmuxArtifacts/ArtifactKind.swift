import Foundation

/// The bounded set of artifact payloads the catalog can safely open or transfer.
///
/// The ``unknown`` case is deliberately retained when a newer cmux writes a
/// kind this build does not understand. Keeping that metadata visible is safer
/// than failing the whole catalog decode or silently treating the value as a
/// text file.
public enum ArtifactKind: Codable, Hashable, CaseIterable, Sendable {
    /// An HTTP or HTTPS destination.
    case url
    /// Inline or file-backed HTML.
    case html
    /// A local regular file that is not otherwise classified.
    case file
    /// Plain text captured with an explicit save request.
    case text
    /// Source code captured with an explicit save request.
    case code
    /// JSON or JSONL captured with an explicit save request.
    case json
    /// A raster or vector image.
    case image
    /// A PDF document.
    case pdf
    /// An audio file.
    case audio
    /// A video file.
    case video
    /// A directory reference; the catalog never recursively crawls it.
    case directory
    /// A browser download accepted through the browser download hook.
    case browserDownload
    /// A generated file accepted by an explicit producer hook.
    case generated
    /// A manually saved value.
    case manual
    /// A future kind retained as metadata until a compatible opener exists.
    case unknown(String)

    /// The stable wire spelling used in catalog and CLI payloads.
    public var rawValue: String {
        switch self {
        case .url: "url"
        case .html: "html"
        case .file: "file"
        case .text: "text"
        case .code: "code"
        case .json: "json"
        case .image: "image"
        case .pdf: "pdf"
        case .audio: "audio"
        case .video: "video"
        case .directory: "directory"
        case .browserDownload: "browserDownload"
        case .generated: "generated"
        case .manual: "manual"
        case .unknown(let value): value
        }
    }

    /// Decodes a known wire spelling or preserves an unknown future value.
    public init(rawValue: String) {
        switch rawValue {
        case "url": self = .url
        case "html": self = .html
        case "file": self = .file
        case "text": self = .text
        case "code": self = .code
        case "json": self = .json
        case "image": self = .image
        case "pdf": self = .pdf
        case "audio": self = .audio
        case "video": self = .video
        case "directory": self = .directory
        case "browserDownload": self = .browserDownload
        case "generated": self = .generated
        case "manual": self = .manual
        default: self = .unknown(rawValue)
        }
    }

    /// Encodes the stable raw spelling without exposing associated-value shape.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Decodes a known or future kind from its string wire value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    /// The currently understood cases used by pickers and validation UI.
    public static var allCases: [ArtifactKind] {
        [.url, .html, .file, .text, .code, .json, .image, .pdf, .audio, .video,
         .directory, .browserDownload, .generated, .manual]
    }

    /// Infers a safe preview kind from a filename extension or MIME type.
    ///
    /// - Parameters:
    ///   - pathExtension: Filename extension without the leading dot.
    ///   - mimeType: Optional MIME type supplied by a producer.
    /// - Returns: The most specific supported kind, or ``file``.
    public init(pathExtension: String = "", mimeType: String? = nil) {
        let extensionValue = pathExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            .lowercased()
        let mime = mimeType?.lowercased() ?? ""
        if mime == "text/html" || ["html", "htm"].contains(extensionValue) {
            self = .html
        } else if mime == "application/pdf" || extensionValue == "pdf" {
            self = .pdf
        } else if mime.hasPrefix("image/") || [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "svg",
        ].contains(extensionValue) {
            self = .image
        } else if mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aac", "flac", "ogg"].contains(extensionValue) {
            self = .audio
        } else if mime.hasPrefix("video/") || ["mp4", "mov", "m4v", "webm", "avi"].contains(extensionValue) {
            self = .video
        } else if ["json", "jsonl"].contains(extensionValue) || mime == "application/json" {
            self = .json
        } else if [
            "swift", "m", "mm", "c", "h", "cc", "cpp", "rs", "go", "py", "js", "ts", "tsx", "jsx",
            "java", "kt", "rb", "php", "sh", "zsh", "fish", "sql", "css", "scss",
        ].contains(extensionValue) {
            self = .code
        } else if ["txt", "log", "md", "markdown", "yaml", "yml", "toml", "csv", "tsv", "xml"].contains(extensionValue)
                    || mime.hasPrefix("text/") {
            self = .text
        } else {
            self = .file
        }
    }

    /// Whether the payload is expected to contain UTF-8 searchable content.
    public var isTextSearchable: Bool {
        switch self {
        case .html, .text, .code, .json, .manual, .generated:
            true
        case .url, .file, .image, .pdf, .audio, .video, .directory, .browserDownload:
            false
        case .unknown:
            false
        }
    }

    /// Whether this kind normally represents a path on disk.
    public var isFileBacked: Bool {
        switch self {
        case .html, .file, .image, .pdf, .audio, .video, .directory, .browserDownload, .generated:
            true
        case .url, .text, .code, .json, .manual:
            false
        case .unknown:
            false
        }
    }
}
