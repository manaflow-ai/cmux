public import Foundation

/// One local file that a trusted diff-viewer session may serve.
public struct CmuxDiffViewerRegisteredFile: Equatable, Sendable {
    /// The absolute URL path exposed through the custom scheme.
    public let requestPath: String

    /// The local file backing ``requestPath``.
    public let fileURL: URL

    /// The allowlisted response MIME type.
    public let mimeType: String

    /// The validated file size, when the file has already been prepared.
    public let fileSize: Int?

    /// Creates an allowlist entry that a session preparer validates before use.
    ///
    /// - Parameters:
    ///   - requestPath: Absolute custom-scheme path exposed to the viewer.
    ///   - fileURL: Local file backing `requestPath`.
    ///   - mimeType: Response MIME type expected for the path extension.
    ///   - fileSize: Previously validated size, or `nil` for an unprepared entry.
    public init(
        requestPath: String,
        fileURL: URL,
        mimeType: String,
        fileSize: Int? = nil
    ) {
        self.requestPath = requestPath
        self.fileURL = fileURL
        self.mimeType = mimeType
        self.fileSize = fileSize
    }
}
