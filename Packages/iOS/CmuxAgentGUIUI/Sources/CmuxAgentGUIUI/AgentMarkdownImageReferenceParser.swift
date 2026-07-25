import Foundation

struct AgentMarkdownImageReference: Hashable, Sendable {
    let altText: String?
    let hostPath: String
    let pixelWidth: Int?
    let pixelHeight: Int?
}

enum AgentMarkdownImageSegment: Hashable, Sendable {
    case text(String)
    case image(AgentMarkdownImageReference)
}

enum AgentMarkdownImageReferenceParser {
    static func segments(in markdown: String) -> [AgentMarkdownImageSegment] {
        guard markdown.contains("]("), markdown.contains("![") else {
            return [.text(markdown)]
        }
        let pattern = #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^)\s]+))(?:\s+(?:"([^"]*)"|'([^']*)'))?\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return [.text(markdown)]
        }
        let fullRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        let matches = expression.matches(in: markdown, range: fullRange)
        guard !matches.isEmpty else {
            return [.text(markdown)]
        }

        let source = markdown as NSString
        var parsed: [AgentMarkdownImageSegment] = []
        var pendingTextStart = markdown.startIndex

        for match in matches {
            guard let matchRange = Range(match.range, in: markdown),
                  let reference = reference(from: match, source: source) else {
                continue
            }
            appendText(
                String(markdown[pendingTextStart ..< matchRange.lowerBound]),
                to: &parsed
            )
            parsed.append(.image(reference))
            pendingTextStart = matchRange.upperBound
        }

        appendText(String(markdown[pendingTextStart...]), to: &parsed)
        return parsed.isEmpty ? [.text(markdown)] : parsed
    }

    private static func reference(
        from match: NSTextCheckingResult,
        source: NSString
    ) -> AgentMarkdownImageReference? {
        guard let rawPath = firstCapture(in: match, indexes: [2, 3], source: source),
              let hostPath = normalizedHostPath(rawPath),
              isLikelyImagePath(hostPath) else {
            return nil
        }
        let altText = firstCapture(in: match, indexes: [1], source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = firstCapture(in: match, indexes: [4, 5], source: source)
        let dimensions = inferredDimensions(rawPath: rawPath, title: title)
        return AgentMarkdownImageReference(
            altText: altText?.isEmpty == false ? altText : nil,
            hostPath: hostPath,
            pixelWidth: dimensions?.width,
            pixelHeight: dimensions?.height
        )
    }

    private static func firstCapture(
        in match: NSTextCheckingResult,
        indexes: [Int],
        source: NSString
    ) -> String? {
        for index in indexes where match.range(at: index).location != NSNotFound {
            return source.substring(with: match.range(at: index))
        }
        return nil
    }

    private static func normalizedHostPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), url.isFileURL {
            return url.path
        }
        if let components = URLComponents(string: trimmed),
           components.scheme == nil,
           components.path.hasPrefix("/") {
            return components.path
        }
        guard trimmed.hasPrefix("/") else { return nil }
        return trimmed
    }

    private static func isLikelyImagePath(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "apng", "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp":
            return true
        default:
            return false
        }
    }

    private static func appendText(_ text: String, to segments: inout [AgentMarkdownImageSegment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .text(let previous) = segments.last {
            segments[segments.count - 1] = .text("\(previous)\n\(trimmed)")
        } else {
            segments.append(.text(trimmed))
        }
    }

    private static func inferredDimensions(
        rawPath: String,
        title: String?
    ) -> (width: Int, height: Int)? {
        if let dimensions = title.flatMap(dimensions(in:)) {
            return dimensions
        }
        if let dimensions = dimensionsFromQueryItems(in: rawPath) {
            return dimensions
        }
        if let dimensions = dimensions(in: rawPath.removingPercentEncoding ?? rawPath) {
            return dimensions
        }
        return dimensionsFromTrailingPathComponents(in: rawPath)
    }

    private static func dimensionsFromQueryItems(in rawPath: String) -> (width: Int, height: Int)? {
        guard let components = URLComponents(string: rawPath),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else {
            return nil
        }
        var values: [String: Int] = [:]
        for item in queryItems {
            guard let value = item.value.flatMap(Int.init),
                  isValidDimension(value) else {
                continue
            }
            values[item.name.lowercased()] = value
        }
        let width = values["w"] ?? values["width"] ?? values["pixel_width"] ?? values["pixelwidth"]
        let height = values["h"] ?? values["height"] ?? values["pixel_height"] ?? values["pixelheight"]
        guard let width, let height else { return nil }
        return (width, height)
    }

    private static func dimensionsFromTrailingPathComponents(in rawPath: String) -> (width: Int, height: Int)? {
        guard let components = URLComponents(string: rawPath) else { return nil }
        let parts = components.path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard parts.count >= 2,
              let width = Int(parts[parts.count - 2]),
              let height = Int(parts[parts.count - 1]),
              isValidDimension(width),
              isValidDimension(height) else {
            return nil
        }
        return (width, height)
    }

    private static func dimensions(in text: String) -> (width: Int, height: Int)? {
        let patterns = [
            #"(?i)(?:^|[^0-9])(?:w|width|pixel_width|pixelwidth)\s*[:=_-]?\s*([0-9]{1,6})[^0-9]+(?:h|height|pixel_height|pixelheight)\s*[:=_-]?\s*([0-9]{1,6})(?:[^0-9]|$)"#,
            #"(?i)(?:^|[^0-9])(?:h|height|pixel_height|pixelheight)\s*[:=_-]?\s*([0-9]{1,6})[^0-9]+(?:w|width|pixel_width|pixelwidth)\s*[:=_-]?\s*([0-9]{1,6})(?:[^0-9]|$)"#,
            #"(?i)(?:^|[^0-9])([0-9]{1,6})\s*(?:x|×)\s*([0-9]{1,6})(?:[^0-9]|$)"#,
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                continue
            }
            let range = NSRange(text.startIndex ..< text.endIndex, in: text)
            guard let match = expression.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let first = capturedInt(in: match, at: 1, text: text),
                  let second = capturedInt(in: match, at: 2, text: text) else {
                continue
            }
            let width = index == 1 ? second : first
            let height = index == 1 ? first : second
            guard isValidDimension(width), isValidDimension(height) else {
                continue
            }
            return (width, height)
        }
        return nil
    }

    private static func capturedInt(
        in match: NSTextCheckingResult,
        at index: Int,
        text: String
    ) -> Int? {
        guard match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return Int(text[range])
    }

    private static func isValidDimension(_ value: Int) -> Bool {
        value > 0 && value <= 200_000
    }
}
