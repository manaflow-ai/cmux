import Foundation

actor TextBoxInlineAttachmentThumbnailSource {
    private let fileURL: URL
    private let normalizer: any TextBoxInlineAttachmentThumbnailNormalizing
    private var cachedSize: TextBoxInlineAttachmentThumbnailSize?
    private var cachedThumbnail: TextBoxInlineAttachmentThumbnailPixels?
    private var failedSize: TextBoxInlineAttachmentThumbnailSize?

    init(
        fileURL: URL,
        normalizer: any TextBoxInlineAttachmentThumbnailNormalizing =
            TextBoxInlineAttachmentThumbnailNormalizer()
    ) {
        self.fileURL = fileURL
        self.normalizer = normalizer
    }

    func thumbnail(
        pixelSize: TextBoxInlineAttachmentThumbnailSize
    ) -> TextBoxInlineAttachmentThumbnailPixels? {
        guard !isCurrentTaskCancelled() else { return nil }
        if cachedSize == pixelSize {
            return cachedThumbnail
        }
        guard failedSize != pixelSize else { return nil }

        let thumbnail = normalizer.normalizedThumbnail(
            for: fileURL,
            pixelSize: pixelSize
        )
        guard !isCurrentTaskCancelled() else { return nil }
        guard let thumbnail else {
            failedSize = pixelSize
            return nil
        }
        cachedSize = pixelSize
        cachedThumbnail = thumbnail
        failedSize = nil
        return thumbnail
    }

    private func isCurrentTaskCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled == true }
    }
}
