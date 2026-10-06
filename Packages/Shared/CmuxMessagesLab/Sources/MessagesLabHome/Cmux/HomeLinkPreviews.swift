import CmuxHomeCore
import Foundation

/// Home's rule for MessagesLab's link previews (README, Link previews): the
/// projection store asks for a preview of every link card it sends or
/// receives; this gate lets through only links the user or an agent (the
/// Chief) sent, so a preview never requests a URL another person chose, and
/// only to a public host (`LinkPreviewAddressPolicy`, resolved off main).
/// Fetched previews stay in `LinkPreviews`' cache (`cached`) for rebuilds.
/// Main thread only, as LinkPreviews.
final class HomeLinkPreviews: LinkPreviewFetching {
    let previews: LinkPreviews
    private var allowed: Set<String> = []

    init(_ previews: LinkPreviews = .shared) { self.previews = previews }

    func cached(_ url: String) -> LinkMetadata? { previews.cached(url) }

    /// The links of a message about to enter the projection, when its sender may cause a fetch.
    func allow(_ parts: [Part]) {
        for case let .link(url, _, _, _, _) in parts { allowed.insert(url) }
    }

    /// The cards a send of this draft text makes (MessagesLab's send uses the same rule).
    func allowSend(_ text: String) { allow(TextParts.parts(for: text)) }

    func fetch(_ url: String, done: @escaping (LinkMetadata) -> Void) {
        guard allowed.contains(url), let parsed = LinkPreviewAddressPolicy.allowsURL(url) else { return }
        if let hit = previews.cached(url) { done(hit); return }
        let previews = self.previews
        // task-owner: one name resolution; ends with the fetch or nothing
        DispatchQueue.global(qos: .utility).async {
            guard LinkPreviewAddressPolicy.resolvesPublic(parsed) else { return }
            DispatchQueue.main.async { previews.fetch(url, done: done) }
        }
    }
}
