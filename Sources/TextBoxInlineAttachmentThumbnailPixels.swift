import Foundation

struct TextBoxInlineAttachmentThumbnailPixels: Sendable {
    let size: TextBoxInlineAttachmentThumbnailSize
    let bytesPerRow: Int
    let rgba8: Data
}
