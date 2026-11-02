public import Foundation

/// Re-encoded image bytes and thumbnail data ready for mobile attachment staging.
///
/// The encoded payload is bounded so the mobile model receives a practical
/// representation. The source file itself has no 8 MiB admission limit; large
/// images are downsampled or re-encoded by ``MobileImageAttachmentPreparer``.
/// This value contains derived bytes only; it does not retain or transport the
/// original file. Original-file preservation belongs to attachment staging.
public struct MobilePreparedImageAttachment: Equatable, Sendable {
    /// Re-encoded PNG or JPEG bytes, never larger than the preparer's target.
    public let data: Data
    /// Lowercase extension matching ``data`` (`png` or `jpg`).
    public let format: String
    /// Bounded PNG thumbnail suitable for a large Retina attachment preview.
    public let thumbnailData: Data?

    /// Creates a prepared image attachment.
    ///
    /// - Parameters:
    ///   - data: Re-encoded image bytes within the preparer's target.
    ///   - format: Lowercase encoded format.
    ///   - thumbnailData: Optional small PNG preview.
    public init(data: Data, format: String, thumbnailData: Data?) {
        self.data = data
        self.format = format
        self.thumbnailData = thumbnailData
    }
}
