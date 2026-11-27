import AppKit
import Foundation

struct TextBoxInlineAttachmentThumbnailRequest: Hashable, Sendable {
    let attachmentID: UUID
    let source: TextBoxInlineAttachmentThumbnailSource
    let pixelSize: TextBoxInlineAttachmentThumbnailSize
    let pointSize: NSSize

    static func == (
        lhs: TextBoxInlineAttachmentThumbnailRequest,
        rhs: TextBoxInlineAttachmentThumbnailRequest
    ) -> Bool {
        lhs.attachmentID == rhs.attachmentID && lhs.pixelSize == rhs.pixelSize
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(attachmentID)
        hasher.combine(pixelSize)
    }
}
