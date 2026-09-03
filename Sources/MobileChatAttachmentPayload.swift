import Foundation
import CmuxTerminal

/// One mobile-chat attachment after RPC validation and before materialization.
struct MobileChatAttachmentPayload: Sendable {
    /// Maximum number of image attachments admitted in one chat submission.
    static let maximumCount = 10
    /// Maximum decoded image bytes retained while one chat submission is built.
    static let maximumTotalDecodedBytes = 32 * 1024 * 1024
    /// Maximum decoded bytes accepted for one image before it reaches disk.
    static let maximumPerAttachmentDecodedBytes =
        TerminalPasteboardService.maximumImageDataByteCount
    /// Conservative base64 budget checked before any payload is decoded.
    static let maximumTotalEncodedBytes =
        ((maximumTotalDecodedBytes + 2) / 3) * 4
    /// Conservative per-image base64 budget checked before decoding.
    static let maximumPerAttachmentEncodedBytes =
        ((maximumPerAttachmentDecodedBytes + 2) / 3) * 4

    let encodedData: String
    let fileExtension: String

    /// Whether encoded payloads fit the count and pre-decode memory budget.
    ///
    /// The exact decoded total is checked again after base64 decoding because
    /// malformed or padded input can decode to fewer bytes than its encoded
    /// length suggests.
    static func encodedBatchFitsAdmissionBudget(
        _ attachments: [Self]
    ) -> Bool {
        guard attachments.count <= maximumCount else { return false }

        var totalEncodedBytes = 0
        for attachment in attachments {
            let encodedBytes = attachment.encodedData.utf8.count
            guard encodedBytes > 0,
                  encodedBytes <= maximumPerAttachmentEncodedBytes else {
                return false
            }
            let (nextTotal, overflowed) =
                totalEncodedBytes.addingReportingOverflow(encodedBytes)
            guard !overflowed, nextTotal <= maximumTotalEncodedBytes else {
                return false
            }
            totalEncodedBytes = nextTotal
        }
        return true
    }
}
