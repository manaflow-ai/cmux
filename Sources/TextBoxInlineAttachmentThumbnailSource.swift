import Foundation

actor TextBoxInlineAttachmentThumbnailSource {
    private let fileURL: URL
    private let normalizer: any TextBoxInlineAttachmentThumbnailNormalizing
    private var thumbnails: [
        TextBoxInlineAttachmentThumbnailSize: TextBoxInlineAttachmentThumbnailPixels
    ] = [:]
    private var failedSizes: Set<TextBoxInlineAttachmentThumbnailSize> = []

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
        if let thumbnail = thumbnails[pixelSize] {
            return thumbnail
        }
        guard !failedSizes.contains(pixelSize) else { return nil }

        guard let thumbnail = normalizer.normalizedThumbnail(
            for: fileURL,
            pixelSize: pixelSize
        ) else {
            failedSizes.insert(pixelSize)
            return nil
        }
        thumbnails[pixelSize] = thumbnail
        return thumbnail
    }
}
