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
        let urls = Self.previewableCardURLs(shown, summary: shownSummary, me: me, asked: askedLinkPreviews, limit: Self.previewsPerPass) {
            store.state.message(HomeMapping.id($0, aliases: self.aliases))?.parts ?? []
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

    /// Whether `author`'s cards may fetch their previews here: the person's own messages and their
    /// Chief's replies, never another person's or another agent's.
    static func fetchesPreviews(of author: ParticipantID, me: ParticipantID, summary: ConversationSummary?) -> Bool {
        author == me || HomeMapping.isChief(author, summary)
    }

    /// The card URLs among `items` (newest first) that may fetch and still show the domain card (no
    /// picture, no title but the site's), not in `asked`, at most `limit`. `parts` gives an item's
    /// shown parts (the projection store's message).
    static func previewableCardURLs(_ items: [TranscriptItem], summary: ConversationSummary?, me: ParticipantID,
                                    asked: Set<String>, limit: Int, parts: (TranscriptItem) -> [Part]) -> [String] {
        var out: [String] = []
        var seen = asked
        for item in items.reversed() where !item.isRetracted && fetchesPreviews(of: item.author, me: me, summary: summary) {
            for case let .link(url, title, site, image, _) in parts(item) where image == nil && (title == nil || title == site) {
                guard seen.insert(url).inserted else { continue }
                out.append(url)
                if out.count >= limit { return out }
            }
        }
        return out
    }
}
