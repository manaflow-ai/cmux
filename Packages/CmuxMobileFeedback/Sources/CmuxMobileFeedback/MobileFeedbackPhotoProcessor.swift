#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Background image encoder for optional mobile feedback photo attachments.
public struct MobileFeedbackPhotoProcessor: Sendable {
    /// Creates a photo processor.
    public init() {}

    /// Builds a bounded JPEG attachment from raw image bytes.
    ///
    /// The decode, resize, and JPEG compression loop runs in a detached task so
    /// selecting large photos does not block SwiftUI's main actor.
    ///
    /// - Parameters:
    ///   - sourceData: Original image data loaded from PhotosPicker.
    ///   - index: 1-based attachment index used in the generated filename.
    ///   - maximumByteCount: Per-photo byte budget.
    /// - Returns: A prepared JPEG attachment.
    public func makeAttachment(
        from sourceData: Data,
        index: Int,
        maximumByteCount: Int
    ) async throws -> MobileFeedbackPhotoAttachment {
        try await Task.detached(priority: .userInitiated) {
            let boundedMaximumByteCount = max(maximumByteCount, 1)
            let jpegData = try Self.optimizedJPEGData(
                from: sourceData,
                maximumByteCount: boundedMaximumByteCount
            )
            return MobileFeedbackPhotoAttachment(
                id: UUID(),
                fileName: "feedback-photo-\(index).jpg",
                mimeType: "image/jpeg",
                data: jpegData
            )
        }.value
    }

    private static func optimizedJPEGData(
        from sourceData: Data,
        maximumByteCount: Int
    ) throws -> Data {
        let maxPixelDimensions = [2_800, 2_400, 2_000, 1_600, 1_280, 1_024, 768, 640, 512]
        let compressionQualities = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]

        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw MobileFeedbackSubmissionError.photoReadFailed
        }

        for maxPixelDimension in maxPixelDimensions {
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
                continue
            }

            for compressionQuality in compressionQualities {
                guard let data = jpegData(from: image, quality: compressionQuality) else { continue }
                if data.count <= maximumByteCount {
                    return data
                }
            }
        }

        throw MobileFeedbackSubmissionError.photoPreparationFailed
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return data as Data
    }
}
#endif
