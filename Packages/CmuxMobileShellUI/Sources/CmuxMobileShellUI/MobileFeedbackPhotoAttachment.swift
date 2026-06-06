#if os(iOS)
import Foundation
import PhotosUI
import SwiftUI
import UIKit

struct MobileFeedbackPhotoAttachment: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let mimeType: String
    let data: Data

    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }

    @MainActor
    static func make(
        from item: PhotosPickerItem,
        index: Int,
        maximumByteCount: Int
    ) async throws -> MobileFeedbackPhotoAttachment {
        guard let sourceData = try await item.loadTransferable(type: Data.self),
              let image = UIImage(data: sourceData) else {
            throw MobileFeedbackSubmissionError.photoReadFailed
        }

        let boundedMaximumByteCount = max(maximumByteCount, 128 * 1_024)
        guard let jpegData = optimizedJPEGData(
            from: image,
            maximumByteCount: boundedMaximumByteCount
        ) else {
            throw MobileFeedbackSubmissionError.photoPreparationFailed
        }

        return MobileFeedbackPhotoAttachment(
            id: UUID(),
            fileName: "feedback-photo-\(index).jpg",
            mimeType: "image/jpeg",
            data: jpegData
        )
    }

    @MainActor
    private static func optimizedJPEGData(
        from image: UIImage,
        maximumByteCount: Int
    ) -> Data? {
        let maxPixelDimensions: [CGFloat] = [2_800, 2_400, 2_000, 1_600, 1_280, 1_024, 768, 640, 512]
        let compressionQualities: [CGFloat] = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]

        for maxPixelDimension in maxPixelDimensions {
            let resizedImage = image.resizedForFeedback(maxPixelDimension: maxPixelDimension)
            for compressionQuality in compressionQualities {
                guard let data = resizedImage.jpegData(compressionQuality: compressionQuality) else { continue }
                if data.count <= maximumByteCount {
                    return data
                }
            }
        }

        return nil
    }
}

private extension UIImage {
    @MainActor
    func resizedForFeedback(maxPixelDimension: CGFloat) -> UIImage {
        let largestDimension = max(size.width, size.height)
        guard largestDimension > maxPixelDimension, largestDimension > 0 else { return self }

        let scale = maxPixelDimension / largestDimension
        let targetSize = CGSize(
            width: max(size.width * scale, 1),
            height: max(size.height * scale, 1)
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
#endif
