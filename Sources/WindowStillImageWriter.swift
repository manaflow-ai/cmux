import CmuxFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes one captured frame to a png or a jpeg.
///
/// The counterpart of `WindowRecordingFrameWriter` for a single image: same
/// promise that the caller's path only ever holds a complete file, through the
/// same working-file handling.
enum WindowStillImageWriter {
    enum Failure: Error, LocalizedError {
        case outputNotAFile(String)
        case encodeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .outputNotAFile(path):
                "\(path) is not a file the screenshot may replace"
            case let .encodeFailed(detail):
                "the screenshot could not be written: \(detail)"
            }
        }
    }

    /// The file a screenshot produced.
    struct Written {
        let url: URL
        let width: Int
        let height: Int
        let byteCount: Int
    }

    static func write(
        _ image: CGImage,
        to outputURL: URL,
        format: WindowScreenshotRequest.Format,
        quality: Double
    ) throws -> Written {
        guard WindowCaptureOutputFile.isReplaceable(at: outputURL) else {
            throw Failure.outputNotAFile(outputURL.path)
        }
        let workingURL = WindowCaptureOutputFile.workingURL(
            for: outputURL,
            discriminator: "screenshot-\(UUID().uuidString.prefix(8).lowercased())"
        )
        try WindowCaptureOutputFile.prepare(outputURL: outputURL, workingURL: workingURL)

        do {
            try encode(image, to: workingURL, format: format, quality: quality)
            try WindowCaptureOutputFile.promote(from: workingURL, to: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: workingURL)
            throw error
        }

        let byteCount = (try? FileManager.default.attributesOfItem(atPath: outputURL.path))
            .flatMap { $0[.size] as? Int } ?? 0
        return Written(
            url: outputURL,
            width: image.width,
            height: image.height,
            byteCount: byteCount
        )
    }

    private static func encode(
        _ image: CGImage,
        to url: URL,
        format: WindowScreenshotRequest.Format,
        quality: Double
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            contentType(for: format).identifier as CFString,
            1,
            nil
        ) else {
            throw Failure.encodeFailed("could not create a \(format.rawValue) at \(url.path)")
        }
        // Quality is meaningless for png, and passing it does no harm, but
        // leaving it out keeps the properties honest about what was applied.
        let properties: CFDictionary? = format.isLossy
            ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            : nil
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.encodeFailed("the \(format.rawValue) could not be finalized")
        }
    }

    private static func contentType(for format: WindowScreenshotRequest.Format) -> UTType {
        switch format {
        case .png: .png
        case .jpeg: .jpeg
        }
    }
}
