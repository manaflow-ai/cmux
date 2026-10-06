import CmuxHomeCore
import Foundation

/// Home's rule for MessagesLab's link previews (README, Link previews), as
/// iMessage does it: the SENDER makes the preview. The projection store asks
/// for a preview of every link card it sends or receives; this gate lets a
/// fetch through only for a link in a message this Mac sends, or a card the
/// user taps. An incoming card never fetches on its own: it shows what the
/// sender attached, else the domain (no request to a URL another person or an
/// agent chose, and the receiver's address never reaches the sender's server).
/// Every fetch goes through MessagesLab's LinkGuard (LinkPreviews: public
/// addresses only, redirects re-checked, an ephemeral session, size caps).
/// Main thread only, as LinkPreviews.
final class HomeLinkPreviews: LinkPreviewFetching {
    let previews: LinkPreviews
    private var allowed: Set<String> = []
    /// URLs passed to LinkPreviews (tests).
    private(set) var requested: [String] = []

    init(_ previews: LinkPreviews = .shared) { self.previews = previews }

    func cached(_ url: String) -> LinkMetadata? { previews.cached(url) }

    /// The cards a send of this draft text makes (MessagesLab's send uses the same rule).
    func allowSend(_ text: String) {
        for case let .link(url, _, _, _, _) in TextParts.parts(for: text) { allowed.insert(url) }
    }

    /// The user tapped a card: its preview may be fetched now.
    func allowTap(_ url: String) { allowed.insert(url) }

    /// This Mac sent the link: LinkPreviews' LinkPresentation fallback may run for it
    /// (a page that builds its tags in script). Never for a received link.
    func allowFallback(_ url: String) {
        guard allowed.contains(url) else { return }
        previews.allowFallback(url)
    }

    func fetch(_ url: String, done: @escaping (LinkMetadata?) -> Void) {
        // Not allowed: a pending card becomes the domain card (Store.apply), nothing is requested.
        guard allowed.contains(url) else { done(nil); return }
        requested.append(url)
        previews.fetch(url, done: done)
    }
}
