import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension ArtifactByteReader {
    /// Decodes a thumbnail from an already-verified descriptor without consulting its pathname.
    func thumbnail(
        verifiedFile: (handle: FileHandle, size: Int64),
        maxDimension: Int
    ) throws -> ChatArtifactThumbnail {
        let provider = try ArtifactImageDataProvider(
            fileDescriptor: verifiedFile.handle.fileDescriptor,
            size: verifiedFile.size
        )
        guard let source = CGImageSourceCreateWithDataProvider(provider.value, nil) else {
            throw ArtifactByteReader.Error.corruptMedia
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ArtifactByteReader.Error.corruptMedia
        }
        guard let destinationData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                destinationData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw ArtifactByteReader.Error.previewFailed
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ArtifactByteReader.Error.previewFailed
        }
        return ChatArtifactThumbnail(
            data: destinationData as Data,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }
}
