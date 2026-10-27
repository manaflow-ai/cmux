#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// What a composer's Paste takes from the pasteboard. Only types are read
/// (no "Allow Paste" prompt); the composer reads the data once the person
/// chose Paste.
public extension UIPasteboard {
    /// An image or a copied file leads the pasteboard: Paste attaches it.
    /// Text that came with an image (cells from Numbers, a note with a
    /// picture) still pastes as text, as the copying app put it first.
    var composerPastesAttachments: Bool {
        guard hasImages || contains(pasteboardTypes: [UTType.fileURL.identifier]) else { return false }
        guard hasStrings else { return true }
        guard let first = types.first.flatMap({ UTType($0) }) else { return false }
        return first.conforms(to: .image) || first.conforms(to: .fileURL)
    }

    /// Each item's image as PNG or JPEG bytes: the copying app's own when it
    /// gave them, else re-encoded as PNG (HEIC, TIFF, an image object).
    func composerImages() -> [(data: Data, mimeType: String)] {
        let own: [(data: Data, mimeType: String)] = (0..<numberOfItems).compactMap { index in
            let item = IndexSet(integer: index)
            let itemTypes = (types(forItemSet: item)?.first ?? []).compactMap { UTType($0) }
            guard let type = itemTypes.first(where: { $0.conforms(to: .image) }),
                  let data = data(forPasteboardType: type.identifier, inItemSet: item)?.first else { return nil }
            if type.conforms(to: .png) { return (data, "image/png") }
            if type.conforms(to: .jpeg) { return (data, "image/jpeg") }
            return UIImage(data: data)?.pngData().map { ($0, "image/png") }
        }
        return own.isEmpty ? (images ?? []).compactMap { image in image.pngData().map { ($0, "image/png") } } : own
    }
}
#endif
