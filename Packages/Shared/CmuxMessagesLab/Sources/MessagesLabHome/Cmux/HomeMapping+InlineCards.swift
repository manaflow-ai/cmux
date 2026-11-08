import CmuxHomeCore
import Foundation

/// cmux: a link inside a sentence gets its preview card too (issue 38178: "Links show a preview
/// card (title, site, image when available), like iMessage link previews"). Messages' own rule
/// (`TextParts.parts`) makes a card only of a line that is a URL alone; the Chief writes its links
/// in prose and Markdown, so its replies showed none. Each bubble's web links (http and https that
/// the link policy allows) get a card right after the bubble, in the order they appear, at most
/// ``maxInlineCards`` per message; the text keeps its links. A URL that already has a card in the
/// message (a URL-only line, a sender's `link_preview` part) gets no second one.
extension HomeMapping {
    /// Cards a message adds for the links in its sentences, at most.
    static let maxInlineCards = 3

    /// `parts` with a card after each text bubble for its web links (see the type note); `owners`
    /// (the HomeStore part each shown part maps to) grows with them, a card owned by its bubble's part.
    static func withInlineCards(_ parts: [Part], owners: [Int], links: Links) -> (parts: [Part], owners: [Int]) {
        var seen = Set(parts.compactMap { part -> String? in
            if case let .link(url, _, _, _, _) = part { return url }
            return nil
        })
        guard parts.contains(where: { if case let .text(_, runs) = $0 { return runs.contains { $0.link != nil } }; return false }) else {
            return (parts, owners)
        }
        var outParts: [Part] = [], outOwners: [Int] = [], added = 0
        for (index, part) in parts.enumerated() {
            let owner = owners[checked: index] ?? index // // crash program: checked
            outParts.append(part)
            outOwners.append(owner)
            guard case let .text(_, runs) = part else { continue }
            for url in inlineCardURLs(runs) where added < maxInlineCards && seen.insert(url).inserted {
                outParts.append(card(url, links: links))
                outOwners.append(owner)
                added += 1
            }
        }
        return (outParts, outOwners)
    }

    /// The web links of a bubble's runs that may be a card, in order (duplicates kept: the caller dedupes).
    static func inlineCardURLs(_ runs: [TextRun]) -> [String] {
        runs.compactMap { run in
            guard let link = run.link, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false, MarkdownLinkPolicy.allows(url) else { return nil }
            return link
        }
    }

    /// A settled message's card for `url`: the preview this Mac already fetched (its sends, the
    /// Chief's replies, a tap), else the domain card (no grey loading card for a settled message).
    static func card(_ url: String, title: String? = nil, site: String? = nil, image: String? = nil, theme: String? = "dark", links: Links) -> Part {
        guard let meta = links(url) else {
            let host = URL(string: url).map(TextParts.host) ?? url
            return .link(url: url, title: title ?? host, siteName: site ?? host, image: image, theme: theme)
        }
        return .link(url: url, title: meta.title ?? title, siteName: meta.site ?? site, image: meta.image ?? image, theme: theme)
    }
}
