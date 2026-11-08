public import Foundation

/// Value-only identity for one attachment included in a task submission.
///
/// Composer snapshots intentionally keep no file handles or local URLs. The
/// upload identifier remains stable for retries of the same logical request,
/// while the byte count makes a changed staged payload a different request.
public struct MobileTaskSubmissionAttachment: Equatable, Sendable {
    /// Stable identifier used as the attachment upload id.
    public let uploadID: UUID
    /// Number of raw bytes in the staged attachment.
    public let byteCount: Int

    /// Creates an attachment request identity.
    ///
    /// - Parameters:
    ///   - uploadID: Stable identifier used for upload retries.
    ///   - byteCount: Number of staged attachment bytes.
    public init(uploadID: UUID, byteCount: Int) {
        self.uploadID = uploadID
        self.byteCount = byteCount
    }
}
