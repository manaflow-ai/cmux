#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Background image encoder for optional mobile feedback photo attachments.
public struct MobileFeedbackPhotoProcessor: Sendable {
    /// Creates a photo processor.
    public init() {}

    /// Builds a bounded JPEG attachment from a file-backed original image.
    ///
    /// The decode, resize, and JPEG compression loop runs in a detached task so
    /// selecting large photos does not block SwiftUI's main actor.
    ///
    /// - Parameters:
    ///   - sourceURL: File URL for the original image.
    ///   - index: 1-based attachment index used in the generated filename.
    ///   - maximumByteCount: Per-photo byte budget.
    /// - Returns: A prepared JPEG attachment.
    public func makeAttachment(
        fromFileAt sourceURL: URL,
        index: Int,
        maximumByteCount: Int
    ) async throws -> MobileFeedbackPhotoAttachment {
        try await Task.detached(priority: .userInitiated) {
            let boundedMaximumByteCount = max(maximumByteCount, 1)
            let jpegData = try self.optimizedJPEGData(
                fromFileAt: sourceURL,
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

    private func optimizedJPEGData(
        fromFileAt sourceURL: URL,
        maximumByteCount: Int
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            throw MobileFeedbackSubmissionError.photoReadFailed
        }
        return try optimizedJPEGData(from: source, maximumByteCount: maximumByteCount)
    }

    private func optimizedJPEGData(
        from source: CGImageSource,
        maximumByteCount: Int
    ) throws -> Data {
        let maxPixelDimensions = [2_800, 2_400, 2_000, 1_600, 1_280, 1_024, 768, 640, 512]
        let compressionQualities = [0.82, 0.72, 0.62, 0.52, 0.42, 0.32]

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

    private func jpegData(from image: CGImage, quality: Double) -> Data? {
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
