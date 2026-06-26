public import Foundation
import UniformTypeIdentifiers

/// Classifies a file URL into a ``FilePreviewMode``.
///
/// Routing happens in two passes. ``initialMode(for:)`` is extension/filename
/// only so the tab can render synchronously; ``mode(for:)`` additionally reads
/// the file's resource content type and sniffs bytes to disambiguate cases an
/// extension cannot decide (binary plists, source extensions that collide with
/// audio/video UTIs such as `.ts`/`.mts`). The known-text filename and
/// extension sets are injectable so callers can specialize the allow-list.
public struct FilePreviewKindResolver: Sendable {
    private enum Resolution: Sendable {
        case resolved(FilePreviewMode)
        case needsSniff
    }

    private let textFilenames: Set<String>
    private let textExtensions: Set<String>

    /// Creates a resolver with the default text filename/extension allow-lists.
    public init(
        textFilenames: Set<String> = [
            ".env",
            ".gitignore",
            ".gitattributes",
            ".npmrc",
            ".zshrc",
            "dockerfile",
            "makefile",
            "gemfile",
            "podfile"
        ],
        textExtensions: Set<String> = [
            "bash", "c", "cc", "cfg", "conf", "cpp", "cs", "css", "csv", "cts", "env",
            "fish", "go", "h", "hpp", "htm", "html", "ini", "java", "js", "json",
            "jsx", "kt", "log", "m", "markdown", "md", "mdx", "mm", "mts", "plist",
            "py", "rb", "rs", "sh", "sql", "swift", "toml", "ts", "tsx", "tsv", "txt",
            "xml", "yaml", "yml", "zsh"
        ]
    ) {
        self.textFilenames = textFilenames
        self.textExtensions = textExtensions
    }

    /// Fully-resolved viewer mode, including resource content-type and byte sniffing.
    public func mode(for url: URL) -> FilePreviewMode {
        switch resolvedResolution(for: url) {
        case .resolved(let mode):
            return mode
        case .needsSniff:
            return sniffLooksLikeText(url: url) ? .text : .quickLook
        }
    }

    /// Synchronous extension/filename-only viewer mode for the initial tab render.
    public func initialMode(for url: URL) -> FilePreviewMode {
        switch initialResolution(for: url) {
        case .resolved(let mode):
            return mode
        case .needsSniff:
            return .quickLook
        }
    }

    /// ``mode(for:)`` evaluated off the main actor.
    public func resolveMode(url: URL) async -> FilePreviewMode {
        await Task.detached(priority: .userInitiated) {
            self.mode(for: url)
        }.value
    }

    /// SF Symbol for the fully-resolved viewer mode.
    public func tabIconName(for url: URL) -> String {
        mode(for: url).iconName
    }

    /// SF Symbol for the synchronous initial viewer mode.
    public func initialTabIconName(for url: URL) -> String {
        initialMode(for: url).iconName
    }

    private func initialResolution(for url: URL) -> Resolution {
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

    private func resolvedResolution(for url: URL) -> Resolution {
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

    private func mediaMode(for type: UTType) -> FilePreviewMode? {
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

    private func contentTypes(for url: URL) -> [UTType] {
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

    private func knownTextFile(url: URL, includeResourceContentType: Bool) -> Bool {
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

    private func knownTextResolutionBeforeMedia(for url: URL, sniffMediaCollisions: Bool) -> Resolution? {
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

    private func looksLikeBinaryPropertyList(url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8)) ?? Data()
        return String(data: data, encoding: .ascii) == "bplist00"
    }

    private func looksLikeMPEGTransportStream(url: URL) -> Bool {
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

    private func sniffLooksLikeText(url: URL) -> Bool {
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

    private func hasUTF16ByteOrderMark(_ data: Data) -> Bool {
        data.count >= 2 && (
            (data[0] == 0xFF && data[1] == 0xFE)
                || (data[0] == 0xFE && data[1] == 0xFF)
        )
    }
}
