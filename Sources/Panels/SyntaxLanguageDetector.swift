import CodeEditLanguages
import Foundation

/// Maps file URLs to a `CodeLanguage` for TreeSitter syntax highlighting.
///
/// Returns `nil` for unsupported extensions or files above the size threshold,
/// which routes the caller to the plain-text editor fallback.
enum SyntaxLanguageDetector {
    private static let supportedExtensions: Set<String> = [
        "agda",
        "bash", "sh",
        "c", "h",
        "swift",
        "cc", "cpp", "cxx", "hpp", "hh",
        "cs",
        "css",
        "dart",
        "ex", "exs",
        "go",
        "hs",
        "htm", "html", "shtml",
        "java", "jav",
        "jl",
        "js", "cjs", "mjs",
        "json",
        "jsx",
        "kt", "kts",
        "lua",
        "md", "mkd", "mkdn", "mdwn", "mdown", "markdown",
        "ml", "mli",
        "php",
        "pl", "pm",
        "py",
        "rb",
        "rs",
        "scala", "sc",
        "sql",
        "toml",
        "ts", "cts", "mts",
        "tsx",
        "v",
        "yaml", "yml",
        "zig",
    ]

    // Files larger than this threshold fall back to PlainFilePreviewEditor
    // to avoid TreeSitter latency spikes on large logs, generated code, etc.
    private static let maxHighlightBytes = 500_000

    // Cache by absolute path and file metadata so repeated previews avoid
    // CodeEdit language detection while still respecting size/content changes.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: CacheEntry] = [:]

    static func language(for url: URL, currentContentUTF8ByteCount: Int? = nil) -> CodeLanguage? {
        guard isHighlightCandidate(url) else { return nil }
        if let currentContentUTF8ByteCount,
           currentContentUTF8ByteCount > maxHighlightBytes {
            return nil
        }

        let key = url.standardizedFileURL.path
        let metadata = metadata(for: url)
        if currentContentUTF8ByteCount == nil,
           let fileSize = metadata.fileSize,
           fileSize > maxHighlightBytes {
            removeCache(key: key)
            return nil
        }

        cacheLock.lock()
        if let cached = cache[key], cached.metadata == metadata {
            cacheLock.unlock()
            return cached.language
        }
        cacheLock.unlock()

        let resolved = CodeLanguage.detectLanguageFrom(url: url)
        updateCache(key: key, metadata: metadata, language: resolved)
        return resolved
    }

    private static func updateCache(key: String, metadata: FileMetadata, language: CodeLanguage?) {
        cacheLock.lock()
        cache[key] = CacheEntry(metadata: metadata, language: language)
        cacheLock.unlock()
    }

    private static func removeCache(key: String) {
        cacheLock.lock()
        cache.removeValue(forKey: key)
        cacheLock.unlock()
    }

    private static func isHighlightCandidate(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let filename = url.lastPathComponent.lowercased()
        return supportedExtensions.contains(ext) || filename == "dockerfile"
    }

    private static func metadata(for url: URL) -> FileMetadata {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return FileMetadata(
            fileSize: values?.fileSize,
            modificationDate: values?.contentModificationDate
        )
    }

    private struct FileMetadata: Equatable {
        let fileSize: Int?
        let modificationDate: Date?
    }

    private struct CacheEntry {
        let metadata: FileMetadata
        let language: CodeLanguage?
    }
}
