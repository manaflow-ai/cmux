import Foundation
import ImageIO

struct TranscriptImageMetadataProbeResult: Equatable, Sendable {
    let byteCount: Int?
    let width: Int?
    let height: Int?
}

enum TranscriptImageMetadataProbe {
    static func metadata(
        hostPath: String?,
        base64EncodedData: String?
    ) -> TranscriptImageMetadataProbeResult {
        if let base64EncodedData,
           let data = Data(base64Encoded: base64EncodedData, options: [.ignoreUnknownCharacters]) {
            let dimensions = imageDimensions(data: data)
            return TranscriptImageMetadataProbeResult(
                byteCount: data.count,
                width: dimensions?.width,
                height: dimensions?.height
            )
        }

        guard let hostPath else {
            return TranscriptImageMetadataProbeResult(byteCount: nil, width: nil, height: nil)
        }
        let expandedPath = (hostPath as NSString).expandingTildeInPath
        let dimensions = imageDimensions(url: URL(fileURLWithPath: expandedPath))
        let byteCount = fileByteCount(path: expandedPath)
        return TranscriptImageMetadataProbeResult(
            byteCount: byteCount,
            width: dimensions?.width,
            height: dimensions?.height
        )
    }

    private static func imageDimensions(data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return imageDimensions(source: source)
    }

    private static func imageDimensions(url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return imageDimensions(source: source)
    }

    private static func imageDimensions(source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = integer(properties[kCGImagePropertyPixelWidth]),
              let height = integer(properties[kCGImagePropertyPixelHeight]),
              width > 0,
              height > 0 else {
            return nil
        }
        return (width, height)
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let int as Int:
            int
        default:
            nil
        }
    }

    private static func fileByteCount(path: String) -> Int? {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }
}
