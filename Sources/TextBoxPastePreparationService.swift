import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares composer paste content, including a small SDR thumbnail, outside the main actor.
struct TextBoxPastePreparationService: Sendable {
    private static let thumbnailMaxPixelSize = 64

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func prepare(
        request: TerminalPasteboardReadRequest
    ) async -> TextBoxPastePreparedContent {
        let terminalContent = await TerminalImageTransferPreparationService().prepare(
            request: request,
            mode: .paste
        )

        switch terminalContent {
        case .insertText(let text):
            return .insertText(text)
        case .reject:
            return .reject
        case .fileURLs(let fileURLs):
            var attachments: [TextBoxPreparedAttachment] = []
            attachments.reserveCapacity(fileURLs.count)
            for fileURL in fileURLs {
                guard !Task.isCancelled else {
                    terminalContent.cleanupTransferredTemporaryFiles()
                    return .reject
                }
                attachments.append(
                    TextBoxPreparedAttachment(
                        fileURL: fileURL,
                        thumbnailPNGData: normalizedThumbnailPNGData(for: fileURL)
                    )
                )
            }
            guard !Task.isCancelled else {
                terminalContent.cleanupTransferredTemporaryFiles()
                return .reject
            }
            return .attachments(attachments)
        }
    }

    private nonisolated func normalizedThumbnailPNGData(for fileURL: URL) -> Data? {
        let pathExtension = fileURL.pathExtension.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .image),
              !Task.isCancelled else {
            return nil
        }

        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(
            fileURL as CFURL,
            sourceOptions
        ) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let sourceThumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ), !Task.isCancelled,
           let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let width = max(1, sourceThumbnail.width)
        let height = max(1, sourceThumbnail.height)
        let bytesPerRow = width * 4
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: sRGB,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.setBlendMode(.copy)
        context.draw(
            sourceThumbnail,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard !Task.isCancelled,
              let normalizedImage = context.makeImage() else {
            return nil
        }

        let encodedData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encodedData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, normalizedImage, nil)
        guard CGImageDestinationFinalize(destination),
              !Task.isCancelled else {
            return nil
        }
        return encodedData as Data
    }
}
