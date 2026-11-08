import Foundation

protocol TextBoxInlineAttachmentThumbnailNormalizing: Sendable {
    func normalizedThumbnail(
        for fileURL: URL,
        pixelSize: TextBoxInlineAttachmentThumbnailSize
    ) -> TextBoxInlineAttachmentThumbnailPixels?
}
