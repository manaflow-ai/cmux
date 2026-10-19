public import Foundation

/// Bounded image bytes and thumbnail data ready for mobile attachment staging.
public struct MobilePreparedImageAttachment: Equatable, Sendable {
    /// Encoded PNG or JPEG bytes, never larger than 8 MiB.
    public let data: Data
    /// Lowercase extension matching ``data`` (`png` or `jpg`).
    public let format: String
    /// Bounded PNG thumbnail suitable for a large Retina attachment preview.
    public let thumbnailData: Data?

    /// Creates a prepared image attachment.
    ///
    /// - Parameters:
    ///   - data: Bounded encoded image bytes.
    ///   - format: Lowercase encoded format.
    ///   - thumbnailData: Optional small PNG preview.
    public init(data: Data, format: String, thumbnailData: Data?) {
        self.data = data
        self.format = format
        self.thumbnailData = thumbnailData
    }
}
