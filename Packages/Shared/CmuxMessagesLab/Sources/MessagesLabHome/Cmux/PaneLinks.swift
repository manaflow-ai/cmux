import AppKit
import CmuxHomeCore

/// cmux: what a click on a bubble's link opens. Every destination is re-checked at click
/// time with `MarkdownLinkPolicy` (only http, https and mailto, plus a host's extra
/// schemes): a refused link is consumed and opens nothing.
enum PaneLinkTarget: Equatable {
    /// A link inside text (detected URL, an agent's Markdown link); nil: refused.
    case text(URL?)
    /// A link card: its stored string and the URL to open (nil: refused).
    case card(String, URL?)
}

extension MarkdownLinkPolicy {
    /// `dest` as a URL a click may open, or nil (the policy refuses it).
    static func url(_ dest: String) -> URL? { sanitize(dest).flatMap(URL.init(string:)) }
}

extension ChatController {
    /// The link under `p` in its bubble, or nil when the point is on no link.
    func linkTarget(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> PaneLinkTarget? {
        let local = CGPoint(x: p.x - hit.body.minX - Fixture.bubblePadX, y: p.y - hit.body.minY - Fixture.bubblePadY)
        // A markdown layout is body-local (its frags already sit at the padding,
        // MarkdownLayout.swift); a TextLayout is text-local.
        let bodyLocal = CGPoint(x: p.x - hit.body.minX, y: p.y - hit.body.minY)
        if let md = hit.row.markdown, let s = md.link(at: bodyLocal) { return .text(MarkdownLinkPolicy.url(s)) }
        if let tl = hit.row.text, let s = tl.link(at: local) { return .text(MarkdownLinkPolicy.url(s)) }
        if case let .link(url, _, _, _, _) = hit.row.part { return .card(url, MarkdownLinkPolicy.url(url)) }
        return nil
    }

    /// Opens the link under `p`, if any; true when the click was on a link (a refused one
    /// opens nothing). A card tap is the one time a received card may fetch its preview
    /// (HomeLinkPreviews).
    func openLink(_ hit: MessagesWindowView.Hit, at p: CGPoint) -> Bool {
        let other = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.command, .shift]) == true
        switch linkTarget(hit, at: p) {
        case let .text(url)?:
            // An agent-message fold's row: expands or collapses in place (HomeStore.toggleAgentMessages).
            if let url, let group = HomeAgentMessageRow.group(toggledBy: url) {
                intents?.toggleAgentMessages(group)
                return true
            }
            // An app link (a workspace, pane, tab, chat or Chief subagent) or a path goes to the host, never to the system.
            if let url, url.isCmuxAppLink || url.isHomePathLink { onAppLink?(url) } else if let url { onOpenLink(url, other) }
        case let .card(raw, url)?:
            if let url { intents?.linkTapped(hit.row.ref, url: raw); onOpenLink(url, other) }
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

extension ChatController {
    /// The link chip under `p` (host coordinates) and its pill on that line, or nil (the host's
    /// hover card anchors to the rect; plans/cmux-next/home-link-chips-DESIGN.md). Text bubbles
    /// only: a table's links (MarkdownLayout) are not chips yet.
    func linkChip(at p: CGPoint) -> HomeLinkChipHit? {
        guard let hit = demo?.hit(p), hit.row.markdown == nil, let tl = hit.row.text else { return nil }
        let local = CGPoint(x: p.x - hit.body.minX - Fixture.bubblePadX, y: p.y - hit.body.minY - Fixture.bubblePadY)
        guard local.y >= 0 else { return nil }
        let i = CrashGuard.int(floor(local.y / Fixture.lineHeight), in: CrashGuard.countRange) // no trap on NaN
        guard let span = tl.chipSpans(line: i).first(where: { local.x >= $0.x0 && local.x < $0.x1 }),
              let url = MarkdownLinkPolicy.url(span.link) else { return nil }
        let hard = hit.row.outgoing ? TextLayout.hardBreakAdvance : Fixture.lineHeight
        let origin = CGPoint(x: hit.body.minX + Fixture.bubblePadX, y: hit.body.minY + Fixture.textBaseline + tl.lineOffset(i, hard: hard))
        return HomeLinkChipHit(url: url, kind: span.kind, rect: HomeLinkChip.pillRect(span, origin: origin))
    }
}
