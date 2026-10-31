import Foundation

/// An agent's running reply as bubble parts: the parts `HomeMapping.parts(.text(text), markdown: true,
/// links:)` gives, so the posted reply takes the bubble's rows with nothing moving, but at the cost of
/// the token, not of the reply (plans/cmux-next/home-streaming-perf-DESIGN.md, 2). Mapping the whole
/// reply again on every token (the inline Markdown parser, the bare-link scan and the link detector
/// over every line) grew each frame with the reply's length.
///
/// - Markdown renders through `HomeMarkdownRenderer`: only the new lines.
/// - A reply without a code fence and under the long-text size splits its link cards by Messages'
///   rule (`TextParts.parts`), each line asked of the link detector once.
/// - A reply that may hold a Mermaid diagram while a diagram renderer is installed maps in full
///   (`HomeMapping.parts`; the splitter's rules stay in one place).
///
/// Main thread only (the projection's).
final class HomeStreamMapper {
    let renderer = HomeMarkdownRenderer()
    /// `TextParts.soleURL` by line (the link detector is the slow part of the card rule).
    private var soleURLs: [String: URL?] = [:]
    /// Mappings in full (the diagram fallback), for tests.
    private(set) var fullMaps = 0

    func parts(_ text: String, links: HomeMapping.Links) -> [Part] {
        if HomeDiagramRowProvider.installed != nil, text.contains("mermaid") {
            fullMaps += 1
            return HomeMapping.parts(.text(text), markdown: true, links: links)
        }
        // HomeMapping.textParts: a fenced block keeps the reply one part, and so does a long text (TextParts.parts).
        if text.contains("```") || text.contains("~~~") || LongText.isLong(text) {
            let (shown, runs) = renderer.render(text)
            return [.text(shown, runs: runs)]
        }
        return cards(text).map { part in
            switch part {
            case let .text(t, _):
                let (shown, runs) = renderer.render(t)
                return .text(shown, runs: runs)
            case let .link(url, title, site, image, theme):
                // As HomeMapping.textParts: a preview fetched before fills the card, else the domain card.
                guard let meta = links(url) else {
                    let host = URL(string: url).map(TextParts.host) ?? url
                    return .link(url: url, title: title ?? host, siteName: site ?? host, image: image, theme: theme)
                }
                return .link(url: url, title: meta.title ?? title, siteName: meta.site ?? site, image: meta.image ?? image, theme: theme)
            default:
                return part
            }
        }
    }

    /// `TextParts.parts(for:)` for a text that is not long, with each line's card check kept. The
    /// text parts carry no runs: Markdown renders them (HomeMapping.textParts drops TextParts' runs).
    private func cards(_ text: String) -> [Part] {
        var parts: [Part] = []
        var pending: [String] = []
        func flush() {
            while pending.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { pending.removeFirst() }
            while pending.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { pending.removeLast() }
            guard !pending.isEmpty else { return }
            parts.append(.text(pending.joined(separator: "\n"), runs: []))
            pending = []
        }
        var fence: Character?
        for line in text.components(separatedBy: "\n") {
            let lead = line.prefix { $0 == " " }.count
            let body = line.drop { $0 == " " }
            if lead < 4, let c = body.first, c == "`" || c == "~", body.hasPrefix(String(repeating: c, count: 3)) {
                if fence == nil { fence = c } else if fence == c { fence = nil }
            }
            if fence == nil, lead < 4, let url = soleURL(line) {
                flush()
                parts.append(.link(url: url.absoluteString, title: nil, siteName: nil, image: nil, theme: "dark"))
            } else {
                pending.append(line)
            }
        }
        flush()
        return parts.isEmpty ? [.text(text, runs: [])] : parts
    }

    private func soleURL(_ line: String) -> URL? {
        if let known = soleURLs[line] { return known }
        let url = TextParts.soleURL(line)
        if soleURLs.count >= 4096 { soleURLs.removeAll(keepingCapacity: true) }
        soleURLs[line] = url
        return url
    }
}
