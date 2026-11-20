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
    /// Fetches one URL's preview; `done` once, on the main thread.
    typealias Fetch = (String, @escaping (LinkMetadata?) -> Void) -> Void

    let previews: LinkPreviews
    private let load: Fetch
    private var allowed: Set<String> = []
    /// Answers from `load` (the same as `previews`' cache unless a test supplies `load`).
    private var answers: [String: LinkMetadata] = [:]
    /// URLs passed to LinkPreviews, once each (tests).
    private(set) var requested: [String] = []

    /// - Parameter fetch: answers in place of `previews` (tests: metadata without the network).
    init(_ previews: LinkPreviews = .shared, fetch: Fetch? = nil) {
        self.previews = previews
        load = fetch ?? { [previews] url, done in previews.fetch(url, done: done) }
    }

    func cached(_ url: String) -> LinkMetadata? { answers[url] ?? previews.cached(url) }

    /// The cards a send of this draft text makes (MessagesLab's send uses the same rule).
    func allowSend(_ text: String) {
        for case let .link(url, _, _, _, _) in TextParts.parts(for: text) { allowed.insert(url) }
    }

    /// The user tapped a card: its preview may be fetched now.
    func allowTap(_ url: String) { allowed.insert(url) }

    func fetch(_ url: String, done: @escaping (LinkMetadata?) -> Void) {
        // Not allowed: a pending card becomes the domain card (Store.apply), nothing is requested.
        guard allowed.contains(url) else { done(nil); return }
        if !requested.contains(url) { requested.append(url) }
        load(url) { [weak self] meta in
            if let meta { self?.answers[url] = meta }
            done(meta)
        }
    }

    /// The preview a send attaches (an allowed URL): LinkPreviews' answer,
    /// shared with the fetch the local card started, after at most its
    /// timeout; nil when it failed.
    @MainActor
    func preview(_ url: String) async -> LinkMetadata? {
        await withCheckedContinuation { continuation in
            fetch(url) { continuation.resume(returning: $0) }
        }
    }
}
