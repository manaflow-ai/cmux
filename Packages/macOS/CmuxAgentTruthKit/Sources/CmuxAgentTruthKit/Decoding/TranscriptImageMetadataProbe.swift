import Foundation
import ImageIO

public struct TranscriptImageMetadataProbeResult: Equatable, Sendable {
    public let byteCount: Int?
    public let width: Int?
    public let height: Int?

    public init(byteCount: Int?, width: Int?, height: Int?) {
        self.byteCount = byteCount
        self.width = width
        self.height = height
    }
}

public enum TranscriptImageMetadataProbe {
    public static func metadata(
        hostPath: String?,
        base64EncodedData: String?
    ) -> TranscriptImageMetadataProbeResult {
        if let base64EncodedData,
           let data = Data(base64Encoded: base64EncodedData, options: [.ignoreUnknownCharacters]) {
            let dimensions = imageDimensions(data: data) ?? svgDimensions(data: data)
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
            ?? svgDimensions(path: expandedPath)
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

    private static func svgDimensions(path: String) -> (width: Int, height: Int)? {
        guard URL(fileURLWithPath: path).pathExtension.lowercased() == "svg",
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 128 * 1_024)) ?? Data()
        return svgDimensions(data: data)
    }

    private static func svgDimensions(data: Data) -> (width: Int, height: Int)? {
        guard let text = String(data: data.prefix(128 * 1_024), encoding: .utf8),
              text.range(of: "<svg", options: [.caseInsensitive]) != nil else {
            return nil
        }
        if let width = svgLength(named: "width", in: text),
           let height = svgLength(named: "height", in: text),
           width > 0,
           height > 0 {
            return (width, height)
        }
        guard let viewBox = svgAttribute(named: "viewBox", in: text) else {
            return nil
        }
        let numbers = viewBox
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .compactMap { Double($0) }
        guard numbers.count >= 4,
              numbers[2] > 0,
              numbers[3] > 0 else {
            return nil
        }
        return (roundedPixelDimension(numbers[2]), roundedPixelDimension(numbers[3]))
    }

    private static func svgLength(named name: String, in text: String) -> Int? {
        guard let rawValue = svgAttribute(named: name, in: text),
              let number = leadingNumber(rawValue),
              number > 0 else {
            return nil
        }
        return roundedPixelDimension(number)
    }

    private static func svgAttribute(named name: String, in text: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\b\#(escapedName)\s*=\s*["']([^"']+)["']"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private static func leadingNumber(_ value: String) -> Double? {
        let pattern = #"^[ \t\r\n]*([+-]?(?:\d+(?:\.\d+)?|\.\d+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
              ),
              let matchRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Double(value[matchRange])
    }

    private static func roundedPixelDimension(_ value: Double) -> Int {
        max(1, Int(value.rounded()))
    }

    private static func fileByteCount(path: String) -> Int? {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }
}
