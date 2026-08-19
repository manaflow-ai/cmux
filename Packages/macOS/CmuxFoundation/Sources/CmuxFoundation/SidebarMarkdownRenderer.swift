public import Foundation

/// Pure text transform converting a workspace-description markdown string into
/// an `AttributedString`, preserving inline markdown attributes and original
/// whitespace/line breaks.
///
/// Shared foundation utility (not sidebar-specific); used to render workspace
/// descriptions in the sidebar and reusable anywhere a lightweight inline
/// markdown render is needed. Construct it with the markdown source and read
/// ``workspaceDescription``.
public struct SidebarMarkdownRenderer {
    private let markdown: String

    public init(markdown: String) {
        self.markdown = markdown
    }

    /// The markdown rendered into an `AttributedString`, interpreting only
    /// inline syntax and preserving whitespace. `nil` when it cannot be parsed.
    /// Links whose display text merely repeats the destination are shortened
    /// to a compact reference; human-chosen link text is never rewritten.
    public var workspaceDescription: AttributedString? {
        guard let rendered = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return nil }
        return Self.shorteningBareLinkText(in: rendered)
    }

    /// Longest shortened link display text; anything longer is middle-truncated.
    private static let maxShortenedLinkTextLength = 32

    /// Rewrites display text only — destinations stay intact. Runs inside the
    /// renderer so every consumer of ``workspaceDescription`` (AppKit sidebar
    /// cells and the SwiftUI description view) shares one shortening policy.
    private static func shorteningBareLinkText(in source: AttributedString) -> AttributedString {
        var output = AttributedString()
        for (link, range) in source.runs[\.link] {
            let segment = source[range]
            guard let link,
                  let attributes = segment.runs.first?.attributes,
                  let shortened = shortenedDisplayText(for: link, replacing: String(segment.characters))
            else {
                output.append(AttributedString(segment))
                continue
            }
            output.append(AttributedString(shortened, attributes: attributes))
        }
        return output
    }

    private static func shortenedDisplayText(for url: URL, replacing displayText: String) -> String? {
        guard isBareAutolinkText(displayText, for: url) else { return nil }
        if let number = gitHubReferenceNumber(in: url) {
            return "#\(number)"
        }
        guard let host = url.host(percentEncoded: false) else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        let compact: String
        if segments.isEmpty {
            compact = host
        } else if segments.count == 1 {
            // A single-segment path elides nothing; an ellipsis would imply hidden segments.
            compact = "\(host)/\(segments[0])"
        } else {
            compact = "\(host)/…/\(segments[segments.count - 1])"
        }
        return middleTruncated(compact)
    }

    /// A link counts as bare when its display text repeats the destination,
    /// tolerating a missing scheme and trailing slashes on either side. The
    /// destination is also compared percent-decoded, because Foundation
    /// percent-encodes non-ASCII path characters that the display text keeps.
    /// (IDN hosts still punycode-diverge and stay unshortened — acceptable.)
    private static func isBareAutolinkText(_ displayText: String, for url: URL) -> Bool {
        let display = comparableLinkText(displayText, scheme: url.scheme)
        if display == comparableLinkText(url.absoluteString, scheme: url.scheme) {
            return true
        }
        guard let decoded = url.absoluteString.removingPercentEncoding else { return false }
        return display == comparableLinkText(decoded, scheme: url.scheme)
    }

    private static func comparableLinkText(_ text: String, scheme: String?) -> Substring {
        var comparable = Substring(text)
        if let scheme,
           let schemeRange = comparable.range(of: "\(scheme)://", options: [.caseInsensitive, .anchored]) {
            comparable = comparable[schemeRange.upperBound...]
        }
        while comparable.hasSuffix("/") {
            comparable = comparable.dropLast()
        }
        return comparable
    }

    /// GitHub pull/issue URLs collapse to the reference number people already
    /// use in prose, regardless of trailing path (e.g. `/files`) or fragment.
    private static func gitHubReferenceNumber(in url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count >= 4,
              segments[2] == "pull" || segments[2] == "issues",
              UInt(segments[3]) != nil
        else { return nil }
        return segments[3]
    }

    private static func middleTruncated(_ text: String) -> String {
        guard text.count > maxShortenedLinkTextLength else { return text }
        let headLength = maxShortenedLinkTextLength / 2
        let tailLength = maxShortenedLinkTextLength - headLength - 1
        return "\(text.prefix(headLength))…\(text.suffix(tailLength))"
    }
}
