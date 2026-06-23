public import Foundation

/// Outcome of loading a file's text for inline preview/editing.
public enum FilePreviewTextLoadResult: Sendable {
    /// The file decoded successfully to `content` using `encoding`.
    case loaded(content: String, encoding: String.Encoding)
    /// The file is missing, too large, or not decodable as text.
    case unavailable
}

/// Outcome of saving edited text back to a file.
public enum FilePreviewTextSaveResult: Sendable {
    /// The content was written successfully.
    case saved
    /// The write failed; `fileExists` reports whether the file is present on
    /// disk at the time of failure.
    case failed(fileExists: Bool)
}

extension URL {
    /// The maximum file size, in bytes, that the inline file-preview text editor
    /// will load. Files larger than this resolve to `.unavailable`.
    public static let filePreviewMaximumLoadedTextBytes: UInt64 = 16 * 1024 * 1024

    /// Loads this file URL's text off the main actor on a user-initiated
    /// detached task, returning a decoded string with its detected encoding or
    /// `.unavailable`.
    public func loadFilePreviewText() async -> FilePreviewTextLoadResult {
        await Task.detached(priority: .userInitiated) {
            self.loadFilePreviewTextSynchronously()
        }.value
    }

    /// Loads this file URL's text synchronously: validates existence and the
    /// `filePreviewMaximumLoadedTextBytes` size cap, then decodes the bytes as
    /// UTF-8, UTF-16, or ISO Latin-1 (in that order).
    public func loadFilePreviewTextSynchronously() -> FilePreviewTextLoadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return .unavailable
        }
        guard let fileSize = try? resourceValues(forKeys: [.fileSizeKey]).fileSize,
              fileSize >= 0,
              UInt64(fileSize) <= URL.filePreviewMaximumLoadedTextBytes else {
            return .unavailable
        }

        do {
            let data = try Data(contentsOf: self)
            guard let decoded = URL.decodeFilePreviewText(data) else {
                return .unavailable
            }
            return .loaded(content: decoded.content, encoding: decoded.encoding)
        } catch {
            return .unavailable
        }
    }

    /// Saves `content` to this file URL off the main actor on a user-initiated
    /// detached task using `encoding`, returning `.saved` or `.failed`.
    public func saveFilePreviewText(
        _ content: String,
        encoding: String.Encoding
    ) async -> FilePreviewTextSaveResult {
        await Task.detached(priority: .userInitiated) {
            guard let data = content.data(using: encoding) else {
                return .failed(fileExists: FileManager.default.fileExists(atPath: self.path))
            }

            do {
                try data.write(to: self, options: [])
                return .saved
            } catch {
                return .failed(fileExists: FileManager.default.fileExists(atPath: self.path))
            }
        }.value
    }

    private static func decodeFilePreviewText(_ data: Data) -> (content: String, encoding: String.Encoding)? {
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
