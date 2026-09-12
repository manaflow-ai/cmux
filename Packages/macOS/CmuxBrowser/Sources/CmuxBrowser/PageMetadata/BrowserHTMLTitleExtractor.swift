import Foundation

/// Extracts a bounded page title from an HTML response prefix.
struct BrowserHTMLTitleExtractor: Sendable {
    func title(from data: Data) -> String? {
        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let html,
              let openRange = html.range(of: "<title", options: [.caseInsensitive]),
              let closeOfOpen = html[openRange.upperBound...].firstIndex(of: ">"),
              let closeRange = html.range(
                of: "</title>",
                options: [.caseInsensitive],
                range: closeOfOpen..<html.endIndex
              ) else {
            return nil
        }
        let rawTitle = html[html.index(after: closeOfOpen)..<closeRange.lowerBound]
        let title = rawTitle
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
