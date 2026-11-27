import AppKit
import CmuxHomeCore
import OSLog

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
        openLink(linkTarget(hit, at: p), ref: hit.row.ref)
    }

    /// Opens `target`, a link of the part `ref`: a click's (above) or an accessibility press's
    /// (`TranscriptLinkElement`), so both open the same way. False when there is no link.
    func openLink(_ target: PaneLinkTarget?, ref: PartRef) -> Bool {
        let other = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: [.command, .shift]) == true
        switch target {
        case let .text(url)?:
            guard let url else { noteLink(Self.linkLine(nil, "refused by the link policy: opened nothing")); return true }
            // An agent-message fold's row: expands or collapses in place (HomeStore.toggleAgentMessages).
            if let group = HomeAgentMessageRow.group(toggledBy: url) {
                intents?.toggleAgentMessages(group)
                return true
            }
            // An app link (a workspace, pane, tab, chat or Chief subagent) or a path goes to the host, never to the system.
            // Each press says where it went (category app.links; goal agent-shortcut-found: run 45968907489's
            // press on "turn it on" logged nothing).
            if url.isCmuxAppLink || url.isHomePathLink {
                if let onAppLink {
                    noteLink(Self.linkLine(url, "handed to the app"))
                    onAppLink(url)
                } else {
                    noteLink(Self.linkLine(url, "taken by no app link handler: opened nothing"))
                }
            } else {
                if url.scheme?.lowercased().hasPrefix("cmux") == true {
                    noteLink(Self.linkLine(url, "is no app link: handed to the system"))
                }
                onOpenLink(url, other)
            }
        case let .card(raw, url)?:
            if let url { intents?.linkTapped(ref, url: raw); onOpenLink(url, other) }
            else { noteLink(Self.linkLine(nil, "on a card refused by the link policy: opened nothing")) }
        case nil:
            return false
        }
        return true
    }

    /// A mouse-up on a link that opened nothing: says what took it (the onboarding walk's turn-on row
    /// reads it, category app.links). Only the dropped path pays for the hit test.
    func noteDroppedLinkClick(at p: CGPoint, _ taker: String) {
        guard let url = linkURL(at: p) else { return }
        noteLink(Self.linkLine(url, "taken by \(taker): opened nothing", press: "click"))
    }

    static let linkLog = Logger(subsystem: "com.cmuxterm.app.next", category: "app.links")

    /// A line of the app.links log: "app link press on host/path what" (hq's link_log matches "app link").
    static func linkLine(_ url: URL?, _ what: String, press: String = "press") -> String {
        guard let url else { return "app link \(press) \(what)" }
        return "app link \(press) on \(url.host ?? "")\(url.path) \(what)"
    }

    /// Logs `line` in category app.links (public: a link's host and path, never its query).
    static func noteLink(_ line: String) {
        linkLog.notice("\(line, privacy: .public)")
    }

    /// Logs `line` and hands it to ``linkNotes`` (tests read the lines there).
    func noteLink(_ line: String) {
        Self.noteLink(line)
        linkNotes?(line)
    }

    /// The URL `target` opens, or nil (refused, or no link).
    static func url(of target: PaneLinkTarget?) -> URL? {
        switch target {
        case let .text(url)?: return url
        case let .card(_, url)?: return url
        case nil: return nil
        }
    }

    /// The URL a click at `p` (host coordinates) opens, or nil (tests, accessibility).
    func linkURL(at p: CGPoint) -> URL? {
        guard let hit = demo?.hit(p) else { return nil }
        return Self.url(of: linkTarget(hit, at: p))
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
