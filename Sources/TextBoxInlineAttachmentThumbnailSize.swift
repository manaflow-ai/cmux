import Foundation

struct TextBoxInlineAttachmentThumbnailSize: Hashable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}
