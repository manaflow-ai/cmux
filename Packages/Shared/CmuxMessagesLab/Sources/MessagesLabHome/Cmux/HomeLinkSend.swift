import CmuxHomeCore
import Foundation

/// The HomeStore parts of a send whose text has URL-only lines (iMessage:
/// the SENDER makes the preview, README Link previews). MessagesLab's own
/// send splits the text by the vendored `TextParts.parts` and shows the grey
/// loading card while `Store.apply` fetches the preview; this waits for the
/// same fetch (LinkPreviews: LinkGuard, its timeout) and sends the parts in
/// that order: `.text` for each text block, `.linkPreview` for each URL line
/// with the fetched title, site and picture. The picture (LinkPreviews' PNG)
/// becomes a JPEG image record that uploads with the message
/// (`HomeStore.prepareLinkPreviewImage`). A failed fetch sends the URL only
/// (a domain card everywhere, as iMessage sends the bare URL); a URL the
/// owner would refuse as a link preview goes as a text line.
@MainActor
struct HomeLinkSend {
    let previews: HomeLinkPreviews?
    let store: HomeStore

    /// True when MessagesLab shows a card for a line of `text`.
    static func hasLinks(_ shown: [Part]) -> Bool {
        shown.contains { if case .link = $0 { return true }; return false }
    }

    /// The parts for MessagesLab's `shown` parts, and the pictures to upload.
    func parts(_ shown: [Part]) async -> (parts: [MessagePart], uploads: [LocalAttachment]) {
        var parts: [MessagePart] = [], uploads: [LocalAttachment] = []
        for part in shown {
            switch part {
            case let .text(text, _):
                parts.append(.text(text))
            case let .link(url, _, _, _, _):
                let meta = await previews?.preview(url)
                var picture: LocalAttachment?
                if let meta, meta.title != nil, let image = meta.image, let file = URL(string: image), file.isFileURL {
                    picture = try? await store.prepareLinkPreviewImage(fileURL: file)
                }
                let image = picture.map { AttachmentDerivedImage(hash: $0.ref.hash, mimeType: $0.ref.mimeType, byteCount: $0.ref.byteCount) }
                guard let link = LinkPreview.sendable(url: url, title: meta?.title, site: meta?.site, image: image) else {
                    parts.append(.text(url))
                    continue
                }
                parts.append(.linkPreview(link))
                if let picture, link.image != nil, !uploads.contains(where: { $0.ref.hash == picture.ref.hash }) {
                    uploads.append(picture)
                }
            default:
                continue
            }
        }
        return (parts, uploads)
    }
}
