public import Foundation

/// A user-selected file to attach to a feedback submission, carrying the
/// resolved name, size, and MIME type read from the URL's resource values.
public struct FeedbackComposerAttachment: Identifiable, Sendable {
    public let id = UUID()
    public let url: URL
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String

    public var standardizedPath: String {
        url.standardizedFileURL.path
    }

    public var displaySize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// Reads the file's resource values, rejecting non-regular files.
    public init(url: URL) throws {
        let resourceValues = try url.resourceValues(forKeys: [
            .contentTypeKey,
            .fileSizeKey,
            .isRegularFileKey,
            .nameKey,
        ])
        guard resourceValues.isRegularFile != false else {
            throw CocoaError(.fileReadUnknown)
        }

        self.url = url
        self.fileName = resourceValues.name ?? url.lastPathComponent
        self.fileSize = Int64(resourceValues.fileSize ?? 0)
        self.mimeType = resourceValues.contentType?.preferredMIMEType ?? "application/octet-stream"
    }
}
