public import Foundation

/// Writes edited preview text back to disk, encoding with the editor's current
/// `String.Encoding` and reporting whether the target file still exists on
/// failure (so the panel can distinguish a deleted file from a write error).
///
/// `writeOptions` is injectable; the default is `[]`, matching a plain
/// `Data.write(to:)`.
public struct FilePreviewTextSaver: Sendable {
    /// Options passed to `Data.write(to:options:)`.
    public let writeOptions: Data.WritingOptions

    /// Creates a saver with the given write options (default `[]`).
    public init(writeOptions: Data.WritingOptions = []) {
        self.writeOptions = writeOptions
    }

    /// Outcome of a save.
    public enum Result: Sendable {
        case saved
        case failed(fileExists: Bool)
    }

    /// Encodes `content` with `encoding` and writes it to `url` off the main actor.
    public func save(content: String, to url: URL, encoding: String.Encoding) async -> Result {
        let writeOptions = self.writeOptions
        return await Task.detached(priority: .userInitiated) {
            guard let data = content.data(using: encoding) else {
                return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
            }

            do {
                try data.write(to: url, options: writeOptions)
                return .saved
            } catch {
                return .failed(fileExists: FileManager.default.fileExists(atPath: url.path))
            }
        }.value
    }
}
