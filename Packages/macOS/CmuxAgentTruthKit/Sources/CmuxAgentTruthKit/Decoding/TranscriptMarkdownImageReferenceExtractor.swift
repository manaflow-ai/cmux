import Foundation

struct TranscriptMarkdownImageReference: Hashable, Sendable {
    let altText: String?
    let hostPath: String
}

enum TranscriptMarkdownImageSegment: Hashable, Sendable {
    case text(String)
    case image(TranscriptMarkdownImageReference)
}

enum TranscriptMarkdownImageReferenceExtractor {
    static func segments(in markdown: String) -> [TranscriptMarkdownImageSegment] {
        guard markdown.contains("]("), markdown.contains("![") else {
            return [.text(markdown)]
        }
        let pattern = #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^)\s]+))(?:\s+(?:"[^"]*"|'[^']*'))?\s*\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return [.text(markdown)]
        }
        let fullRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        let matches = expression.matches(in: markdown, range: fullRange)
        guard !matches.isEmpty else {
            return [.text(markdown)]
        }

        let source = markdown as NSString
        var parsed: [TranscriptMarkdownImageSegment] = []
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
    ) -> TranscriptMarkdownImageReference? {
        guard let rawPath = firstCapture(in: match, indexes: [2, 3], source: source),
              let hostPath = normalizedHostPath(rawPath),
              isLikelyImagePath(hostPath) else {
            return nil
        }
        let altText = firstCapture(in: match, indexes: [1], source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptMarkdownImageReference(
            altText: altText?.isEmpty == false ? altText : nil,
            hostPath: hostPath
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

    private static func appendText(_ text: String, to segments: inout [TranscriptMarkdownImageSegment]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .text(let previous) = segments.last {
            segments[segments.count - 1] = .text("\(previous)\n\(trimmed)")
        } else {
            segments.append(.text(trimmed))
        }
    }
}
