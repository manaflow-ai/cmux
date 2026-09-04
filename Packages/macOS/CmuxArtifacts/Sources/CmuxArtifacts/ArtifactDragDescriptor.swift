import Foundation

/// Stable drag metadata that AppKit adapters can turn into pasteboard items.
public struct ArtifactDragDescriptor: Codable, Equatable, Sendable {
    /// Stable catalog identity carried by the private representation.
    public let artifactID: UUID
    /// Suggested filename for file-backed records.
    public let suggestedFileName: String
    /// A URL string for URL/file representations, when available.
    public let urlString: String?
    /// Plain text fallback for receivers that do not understand the artifact UTI.
    public let plainText: String
    /// MIME/UTI hint selected by the producer.
    public let contentTypeIdentifier: String?

    /// Creates a drag descriptor.
    public init(
        artifactID: UUID,
        suggestedFileName: String,
        urlString: String?,
        plainText: String,
        contentTypeIdentifier: String? = nil
    ) {
        self.artifactID = artifactID
        self.suggestedFileName = suggestedFileName
        self.urlString = urlString
        self.plainText = plainText
        self.contentTypeIdentifier = contentTypeIdentifier
    }
}
