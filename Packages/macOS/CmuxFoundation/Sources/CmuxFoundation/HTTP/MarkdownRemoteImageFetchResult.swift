public import Foundation

/// The decoded payload of a successfully fetched remote markdown image: the raw
/// image bytes plus the canonical `image/*` MIME type they were served with.
public struct MarkdownRemoteImageFetchResult: Sendable {
    /// The raw image bytes, already bounded to the fetcher's maximum size.
    public let data: Data
    /// The canonical `image/*` MIME type (see
    /// ``MarkdownRemoteImageSecurity/canonicalImageMIMEType(_:)``).
    public let mimeType: String

    /// Creates a fetch result wrapping `data` served as `mimeType`.
    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}
