import AppKit

/// cmux: what a click on a bubble's link opens. Every destination is re-checked at click
/// time with `MarkdownLinkPolicy` (only http, https and mailto, plus a host's extra
/// schemes): a refused link is consumed and opens nothing.
enum PaneLinkTarget: Equatable {
    /// A link inside text (detected URL, an agent's Markdown link); nil: refused.
    case text(URL?)
    /// A link card: its stored string and the URL to open (nil: refused).
    case card(String, URL?)
}

extension ChatController {
    /// The link under `p` in its bubble, or nil when the point is on no link.
    func linkTarget(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> PaneLinkTarget? {
        let local = CGPoint(x: p.x - hit.body.minX - Fixture.bubblePadX, y: p.y - hit.body.minY - Fixture.bubblePadY)
        if let md = hit.row.markdown, let s = md.link(at: local) { return .text(MarkdownLinkPolicy.url(s)) }
        if let tl = hit.row.text, let s = tl.link(at: local) { return .text(MarkdownLinkPolicy.url(s)) }
        if case let .link(url, _, _, _, _) = hit.row.part { return .card(url, MarkdownLinkPolicy.url(url)) }
        return nil
    }

    /// Opens the link under `p`, if any; true when the click was on a link (a refused one
    /// opens nothing). A card tap is the one time a received card may fetch its preview
    /// (HomeLinkPreviews).
    func openLink(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> Bool {
        switch linkTarget(hit, at: p) {
        case let .text(url)?:
            if let url { NSWorkspace.shared.open(url) }
        case let .card(raw, url)?:
            if let url { intents?.linkTapped(hit.row.ref, url: raw); NSWorkspace.shared.open(url) }
        case nil:
            return false
        }
        return true
    }

    /// The URL a click at `p` (host coordinates) opens, or nil (tests, accessibility).
    func linkURL(at p: CGPoint) -> URL? {
        guard let hit = demo?.hit(p) else { return nil }
        switch linkTarget(hit, at: p) {
        case let .text(url)?: return url
        case let .card(_, url)?: return url
        case nil: return nil
        }
    }
}
