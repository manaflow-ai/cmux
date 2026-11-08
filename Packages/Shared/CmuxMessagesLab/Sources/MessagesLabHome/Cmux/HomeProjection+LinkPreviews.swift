import CmuxHomeCore
import Foundation

/// cmux: the Chief chat's link cards fill with the page's title, site and picture (issue 38178).
/// A card in a message the person wrote (from any of their devices) or their Chief wrote fetches
/// its preview through `HomeLinkPreviews` (LinkGuard: public addresses only, redirects re-checked,
/// an ephemeral session, size caps); the card then redraws in place (`.linkMetadata`). Another
/// person's or another agent's card keeps what its sender attached, else the domain, until a tap.
/// Each URL is asked once per view, newest messages first, at most ``previewsPerPass`` new asks per
/// store pass; LinkPreviews caches answers (and failures) in memory and on disk, so a reopened
/// chat asks the network for nothing it already knows.
extension HomeProjection {
    /// New preview asks one store pass starts, at most (a long chat opening fills its newest cards first).
    static let previewsPerPass = 8

    /// Asks for the previews of the shown cards that may fetch and have none yet.
    func requestShownLinkPreviews() {
        guard let linkPreviews, !stopped, let store = controller.store else { return }
        let messages = store.state.conversation.messages
        // One index per pass, built only when a candidate exists (no per-item linear search).
        var byID: [ID: [Part]]?
        let aliases = self.aliases
        let urls = Self.previewableCardURLs(shown, summary: shownSummary, me: me, asked: askedLinkPreviews, limit: Self.previewsPerPass) { item in
            if byID == nil { byID = Dictionary(messages.map { ($0.id, $0.parts) }, uniquingKeysWith: { first, _ in first }) }
            return byID?[HomeMapping.id(item, aliases: aliases)] ?? []
        }
        for url in urls {
            askedLinkPreviews.insert(url)
            linkPreviews.allowShown(url)
            linkPreviews.fetch(url) { [weak self] meta in
                guard let self, !self.stopped, let meta, meta.title != nil || meta.image != nil else { return }
                self.controller.dispatch(.linkMetadata(url: url, title: meta.title, site: meta.site, image: meta.image))
            }
        }
    }

    /// Whether `item`'s cards may fetch their previews here: the person's own messages and their
    /// Chief's replies, never another person's or another agent's, also not an agent's message
    /// posted through the person's own CLI or MCP (`HomeAgentSender`: authored as the person).
    static func fetchesPreviews(of item: TranscriptItem, me: ParticipantID, summary: ConversationSummary?) -> Bool {
        if item.author == me { return HomeAgentSender(item, me: me) == nil }
        return HomeMapping.isChief(item.author, summary)
    }

    /// Whether `item` has a web link to show a card for (a cheap test before its parts are looked up).
    static func mayHaveWebLink(_ item: TranscriptItem) -> Bool {
        item.parts.contains { part in
            switch part {
            case .text(let text, _): return text.range(of: "http", options: .caseInsensitive) != nil
            case .linkPreview: return true
            default: return false
            }
        }
    }

    /// The card URLs among `items` (newest first) that may fetch and still show the domain card (no
    /// picture, no title but the site's), not in `asked`, at most `limit`. `parts` gives an item's
    /// shown parts (the projection store's message).
    static func previewableCardURLs(_ items: [TranscriptItem], summary: ConversationSummary?, me: ParticipantID,
                                    asked: Set<String>, limit: Int, parts: (TranscriptItem) -> [Part]) -> [String] {
        var out: [String] = []
        var seen = asked
        for item in items.reversed() where !item.isRetracted && mayHaveWebLink(item) && fetchesPreviews(of: item, me: me, summary: summary) {
            for case let .link(url, title, site, image, _) in parts(item) where image == nil && (title == nil || title == site) {
                guard seen.insert(url).inserted else { continue }
                out.append(url)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
