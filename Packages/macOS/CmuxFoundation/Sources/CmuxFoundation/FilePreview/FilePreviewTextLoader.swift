public import Foundation

/// Reads a file's text content for the preview editor, bounded by a maximum
/// byte cap and a fixed UTF-8 → UTF-16 → ISO Latin-1 decode ladder.
///
/// `maximumLoadedTextBytes` is injectable so callers can specialize the cap;
/// the default is 16 MiB. Files larger than the cap (or that fail every decode)
/// resolve to ``Result/unavailable``.
public struct FilePreviewTextLoader: Sendable {
    /// Largest file, in bytes, the loader will read into memory.
    public let maximumLoadedTextBytes: UInt64

    /// Creates a loader with the given maximum byte cap (default 16 MiB).
    public init(maximumLoadedTextBytes: UInt64 = 16 * 1024 * 1024) {
        self.maximumLoadedTextBytes = maximumLoadedTextBytes
    }

    /// Outcome of a text load.
    public enum Result: Sendable {
        case loaded(content: String, encoding: String.Encoding)
        case unavailable
    }

    /// ``loadSynchronously(url:)`` evaluated off the main actor.
    public func load(url: URL) async -> Result {
        await Task.detached(priority: .userInitiated) {
            self.loadSynchronously(url: url)
        }.value
    }

    /// Reads and decodes the file at `url`, enforcing the byte cap.
    public func loadSynchronously(url: URL) -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .unavailable
        }
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize >= 0,
              UInt64(fileSize) <= maximumLoadedTextBytes else {
            return .unavailable
        }

        do {
            let data = try Data(contentsOf: url)
            guard let decoded = decodeText(data) else {
                return .unavailable
            }
            return .loaded(content: decoded.content, encoding: decoded.encoding)
        } catch {
            return .unavailable
        }
    }

    private func decodeText(_ data: Data) -> (content: String, encoding: String.Encoding)? {
        if let decoded = String(data: data, encoding: .utf8) {
            return (decoded, .utf8)
        }
        if let decoded = String(data: data, encoding: .utf16) {
            return (decoded, .utf16)
        }
        if let decoded = String(data: data, encoding: .isoLatin1) {
            return (decoded, .isoLatin1)
        }
        return nil
    }
}
