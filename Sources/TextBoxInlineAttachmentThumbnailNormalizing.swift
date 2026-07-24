import Foundation

nonisolated protocol TextBoxInlineAttachmentThumbnailNormalizing: Sendable {
    func normalizedThumbnail(
        for fileURL: URL,
        pixelSize: TextBoxInlineAttachmentThumbnailSize
    ) -> TextBoxInlineAttachmentThumbnailPixels?
}
