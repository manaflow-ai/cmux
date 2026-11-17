import CmuxHomeCore
import Foundation

/// cmux: a link inside an agent's sentence gets its preview card too (issue 38178: "Links show a
/// preview card (title, site, image when available), like iMessage link previews"). Messages' own
/// rule (`TextParts.parts`) makes a card only of a line that is a URL alone; the Chief writes its
/// links in prose and Markdown, which Messages never has, so its replies showed none. In an agent's
/// reply each bubble's web links (http and https that the link policy allows) get a card right after
/// the bubble, in the order they appear, at most ``maxInlineCards`` per message, only for a link whose
/// card shows more than its domain (``showsMoreThanItsDomain(_:)``); the text keeps its
/// links. A URL that already has a card in the message (a URL-only line, a sender's `link_preview`
/// part) gets no second one. A person's bubbles keep Messages' rule exactly (LabFixtureParityTests:
/// Home lays out the Messages demo as Messages does), so a person's send and its stored message
/// show the same bubbles.
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
            guard case let .text(text, runs) = part else { continue }
            for url in inlineCardURLs(runs, in: text) where added < maxInlineCards && showsMoreThanItsDomain(url) && seen.insert(url).inserted {
                outParts.append(card(url, links: links))
                outOwners.append(owner)
                added += 1
            }
        }
        return (outParts, outOwners)
    }

    /// The web links of a bubble's runs that may be a card, in order (duplicates kept: the caller
    /// dedupes). A detected link whose text does not spell its scheme ("README.md", "deploy.sh",
    /// which the data detector reads as `http://readme.md`) is no card: only a link written as
    /// `http://` or `https://`, or a Markdown link (its text is a label, its target a URL).
    static func inlineCardURLs(_ runs: [TextRun], in text: String) -> [String] {
        let ns = text as NSString
        return runs.compactMap { run in
            guard let link = run.link, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host?.isEmpty == false, MarkdownLinkPolicy.allows(url) else { return nil }
            let range = NSRange(location: run.start, length: run.length)
            if NSMaxRange(range) <= ns.length {
                let shown = ns.substring(with: range).trimmingCharacters(in: .whitespaces).lowercased()
                // The run's text is the URL itself (a bare or autolinked URL): it must spell the scheme.
                let isURLText = shown == link.lowercased() || URL(string: shown)?.host != nil || shown.contains(".") && !shown.contains(" ")
                if isURLText, !(shown.hasPrefix("http://") || shown.hasPrefix("https://")) { return nil }
            }
            return link
        }
    }

    /// Whether `url`'s inline card can show more than its domain: a page this Mac may fetch, or a
    /// GitHub pull request, issue or commit (titled from its URL). Another GitHub page (a CI run, a
    /// compare view) is never fetched (it needs sign-in), so its card would only repeat "github.com"
    /// under the link: the link stays text. Each card is a transcript row, so a card that says
    /// nothing also costs every frame that lays out the transcript.
    static func showsMoreThanItsDomain(_ url: String) -> Bool {
        !HomeProjection.needsSignIn(url) || gitHubReference(url) != nil
    }

    /// A GitHub pull request, issue or commit link's card title, from its URL alone (`owner/repo#12`,
    /// `owner/repo@abc1234`, GitHub's own reference form): the page itself needs the person's sign-in
    /// (most of the Chief's links are private repositories), so its card is never fetched signed out.
    static func gitHubReference(_ link: String) -> String? {
        guard let kind = HomeLinkChip.kind(for: link), let url = URL(string: link) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        let repo = parts[0] + "/" + parts[1]
        switch kind {
        case .pullRequest, .issue: return repo + "#" + parts[3]
        case .commit: return repo + "@" + String(parts[3].prefix(7))
        default: return nil
        }
    }

    /// A settled message's card for `url`: the preview this Mac already fetched (its sends, the
    /// Chief's replies, a tap), else the domain card (no grey loading card for a settled message).
    static func card(_ url: String, title: String? = nil, site: String? = nil, image: String? = nil, theme: String? = "dark", links: Links) -> Part {
        guard let meta = links(url) else {
            let host = URL(string: url).map(TextParts.host) ?? url
            return .link(url: url, title: title ?? gitHubReference(url) ?? host, siteName: site ?? host, image: image, theme: theme)
        }
        return .link(url: url, title: meta.title ?? title, siteName: meta.site ?? site, image: meta.image ?? image, theme: theme)
    }
}
