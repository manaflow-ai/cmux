public import Foundation
import UniformTypeIdentifiers

/// The rendering mode a file-preview pane uses for a given file: inline text
/// editor, PDF view, image view, AV media player, or a Quick Look fallback.
///
/// `FilePreviewMode` is the owning domain type for file-kind resolution. The
/// kind-resolution logic (extension/UTI tables, off-main content sniffing for
/// binary plists, MPEG-TS detection, UTF-16 BOM checks) lives on this enum as
/// static factory members and the SF Symbol mapping lives as an instance
/// property, rather than on a separate static-utility namespace type.
///
/// All resolution is pure: it reads from the filesystem through `URL`/`UTType`/
/// `FileHandle` only, holds no state, and has no `Workspace`/`TabManager`/
/// `AppDelegate` coupling, so the static factory members are an acceptable home
/// on the owning value type.
public enum FilePreviewMode: Equatable, Sendable {
    /// Inline, editable text content.
    case text
    /// PDF document rendered with PDFKit.
    case pdf
    /// Bitmap or vector image.
    case image
    /// Audio/video content played with AVKit.
    case media
    /// Quick Look fallback for any kind not handled inline.
    case quickLook

    /// Intermediate result of kind resolution: either a settled mode, or a
    /// signal that the caller must sniff file contents to decide.
    public enum Resolution: Sendable {
        /// The file's kind was determined from its name/extension/UTI.
        case resolved(FilePreviewMode)
        /// The kind is ambiguous; sniff the file's bytes to decide.
        case needsSniff
    }

    private static let textFilenames: Set<String> = [
        ".env",
        ".gitignore",
        ".gitattributes",
        ".npmrc",
        ".zshrc",
        "dockerfile",
        "makefile",
        "gemfile",
        "podfile"
    ]

    private static let textExtensions: Set<String> = [
        "bash", "c", "cc", "cfg", "conf", "cpp", "cs", "css", "csv", "cts", "env",
        "fish", "go", "h", "hpp", "htm", "html", "ini", "java", "js", "json",
        "jsx", "kt", "log", "m", "markdown", "md", "mdx", "mm", "mts", "plist",
        "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "tsv", "txt",
        "xml", "yaml", "yml", "zsh"
    ]

    /// The fully resolved preview mode for `url`, sniffing file contents when the
    /// name/extension/UTI is ambiguous (binary plists, source extensions that
    /// collide with audio/video UTIs such as `.ts`/`.mts`).
    public static func resolved(for url: URL) -> FilePreviewMode {
        switch resolvedResolution(for: url) {
        case .resolved(let mode):
            return mode
        case .needsSniff:
            return sniffLooksLikeText(url: url) ? .text : .quickLook
        }
    }

    /// The initial preview mode for `url` determined from name/extension/UTI
    /// only (no content sniffing), used to pick a tab icon before the off-main
    /// resolved mode is available. Ambiguous files fall back to Quick Look.
    public static func initial(for url: URL) -> FilePreviewMode {
        switch initialResolution(for: url) {
        case .resolved(let mode):
            return mode
        case .needsSniff:
            return .quickLook
        }
    }

    /// The fully resolved preview mode for `url`, computed off the main actor on
    /// a user-initiated detached task (content sniffing can hit the disk).
    public static func resolvedOffMain(for url: URL) async -> FilePreviewMode {
        await Task.detached(priority: .userInitiated) {
            resolved(for: url)
        }.value
    }

    /// The SF Symbol name for the tab icon of a file at `url`, using the fully
    /// resolved mode.
    public static func tabIconName(for url: URL) -> String {
        resolved(for: url).iconName
    }

    /// The SF Symbol name for the tab icon of a file at `url`, using the initial
    /// (name/extension-only) mode.
    public static func initialTabIconName(for url: URL) -> String {
        initial(for: url).iconName
    }

    /// The SF Symbol name for this mode's tab icon.
    public var iconName: String {
        switch self {
        case .text:
            return "doc.text"
        case .pdf:
            return "doc.richtext"
        case .image:
            return "photo"
        case .media:
            return "play.rectangle"
        case .quickLook:
            return "doc.viewfinder"
        }
    }

    private static func initialResolution(for url: URL) -> Resolution {
        let ext = url.pathExtension.lowercased()
        if let textResolution = knownTextResolutionBeforeMedia(for: url, sniffMediaCollisions: false) {
            return textResolution
        }

        if let type = UTType(filenameExtension: ext),
           let mediaMode = mediaMode(for: type) {
            return .resolved(mediaMode)
        }

        if ext == "plist" {
            return .needsSniff
        }

        if knownTextFile(url: url, includeResourceContentType: false) {
            return .resolved(.text)
        }

        return .needsSniff
    }

    private static func resolvedResolution(for url: URL) -> Resolution {
        let ext = url.pathExtension.lowercased()
        if ext == "plist", looksLikeBinaryPropertyList(url: url) {
            return .resolved(.quickLook)
        }

        if let textResolution = knownTextResolutionBeforeMedia(for: url, sniffMediaCollisions: true) {
            return textResolution
        }

        for type in contentTypes(for: url) {
            if let mediaMode = mediaMode(for: type) {
                return .resolved(mediaMode)
            }
        }

        if knownTextFile(url: url, includeResourceContentType: true) {
            return .resolved(.text)
        }

        return .needsSniff
    }

    private static func mediaMode(for type: UTType) -> FilePreviewMode? {
        if type.conforms(to: .pdf) {
            return .pdf
        }
        if type.conforms(to: .image) {
            return .image
        }
        if type.conforms(to: .movie)
            || type.conforms(to: .audiovisualContent)
            || type.conforms(to: .audio) {
            return .media
        }
        return nil
    }

    private static func contentTypes(for url: URL) -> [UTType] {
        var types: [UTType] = []
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type != .data {
            types.append(type)
        }
        if let fallbackType = UTType(filenameExtension: url.pathExtension.lowercased()),
           !types.contains(fallbackType) {
            types.append(fallbackType)
        }
        return types
    }

    private static func knownTextFile(url: URL, includeResourceContentType: Bool) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        if textFilenames.contains(filename) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) {
            return true
        }
        if includeResourceContentType,
           let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            return true
        }
        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .text) || type.conforms(to: .sourceCode) {
            return true
        }
        return false
    }

    private static func knownTextResolutionBeforeMedia(for url: URL, sniffMediaCollisions: Bool) -> Resolution? {
        let filename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        guard ext != "plist",
              textFilenames.contains(filename) || textExtensions.contains(ext) else {
            return nil
        }

        guard let type = UTType(filenameExtension: ext),
              let mediaMode = mediaMode(for: type),
              !type.conforms(to: .text),
              !type.conforms(to: .sourceCode) else {
            return .resolved(.text)
        }

        // Source extensions can collide with system audio/video UTIs (.ts, .mts).
        // Initial routing stays extension-only; resolved routing sniffs off-main.
        guard sniffMediaCollisions else {
            return .resolved(.text)
        }
        if sniffLooksLikeText(url: url) {
            return .resolved(.text)
        }
        if looksLikeMPEGTransportStream(url: url) {
            return .resolved(.media)
        }
        return .resolved(mediaMode)
    }

    private static func looksLikeBinaryPropertyList(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8)) ?? Data()
        return String(data: data, encoding: .ascii) == "bplist00"
    }

    private static func looksLikeMPEGTransportStream(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard data.count >= 376 else { return false }

        let syncCandidates = [
            (packetSize: 188, syncOffset: 0),
            (packetSize: 192, syncOffset: 0),
            (packetSize: 192, syncOffset: 4),
            (packetSize: 204, syncOffset: 0)
        ]

        for candidate in syncCandidates where data.count > candidate.syncOffset {
            var offset = candidate.syncOffset
            var syncCount = 0
            while offset < data.count {
                guard data[offset] == 0x47 else { break }
                syncCount += 1
                offset += candidate.packetSize
            }
            if syncCount >= 2 {
                return true
            }
        }

        return false
    }

    private static func sniffLooksLikeText(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !data.isEmpty else { return true }
        if hasUTF16ByteOrderMark(data), String(data: data, encoding: .utf16) != nil {
            return true
        }
        if data.contains(0) {
            return false
        }
        return String(data: data, encoding: .utf8) != nil
    }

    private static func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        data.count >= 2 && (
            (data[0] == 0xFF && data[1] == 0xFE)
                || (data[0] == 0xFE && data[1] == 0xFF)
        )
    }
}
