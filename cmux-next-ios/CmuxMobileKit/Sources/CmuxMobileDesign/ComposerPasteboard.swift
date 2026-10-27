#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// A file pasted into a composer, read once the person chose Paste.
public struct ComposerPastedFile: Sendable {
    public let data: Data
    /// The copying app's name for it (Files: the file's name), with its extension.
    public let name: String
    public let type: UTType
}

/// What a composer's Paste takes from the pasteboard. Only types are read
/// (no "Allow Paste" prompt); the composer reads the data once the person
/// chose Paste.
public extension UIPasteboard {
    /// An image or a copied file leads the pasteboard: Paste attaches it.
    /// Text that came with an image (cells from Numbers, a note with a
    /// picture) still pastes as text, as the copying app put it first.
    var composerPastesAttachments: Bool {
        guard let first = types.first.flatMap({ UTType($0) }) else { return false }
        if first.conforms(to: .image) || first.conforms(to: .fileURL) { return true }
        guard !hasStrings else { return false }
        return hasImages || contains(pasteboardTypes: [UTType.fileURL.identifier]) || Self.isComposerFileType(first)
    }

    /// The pasteboard holds a copied file's own bytes (Files' Copy puts the
    /// file, not its path), not text or an image.
    var composerHoldsFileData: Bool {
        guard !hasStrings, !hasImages, let first = types.first.flatMap({ UTType($0) }) else { return false }
        return Self.isComposerFileType(first)
    }

    /// A copied file's own type (a PDF, an archive, a movie from Files or
    /// Mail): declared, and not text, a web link or an app's private format.
    static func isComposerFileType(_ type: UTType) -> Bool {
        guard type.isDeclared, !type.isDynamic else { return false }
        if type.conforms(to: .text) || type.conforms(to: .url) { return false }
        return type.conforms(to: .data) || type.conforms(to: .package)
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

    /// The copied files on the pasteboard, each read through its item
    /// provider. A file over `maxBytes` is left out and named in `refused`.
    @MainActor
    func composerFiles(maxBytes: Int) async -> (files: [ComposerPastedFile], refused: [String]) {
        var files: [ComposerPastedFile] = []
        var refused: [String] = []
        for provider in itemProviders {
            guard let type = provider.registeredTypeIdentifiers.lazy.compactMap({ UTType($0) })
                .first(where: { Self.isComposerFileType($0) }) else { continue }
            var name = provider.suggestedName ?? String(localized: "Pasted file")
            if let ext = type.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            guard let data, !data.isEmpty else { continue }
            guard data.count <= maxBytes else {
                refused.append(name)
                continue
            }
            files.append(ComposerPastedFile(data: data, name: name, type: type))
        }
        return (files, refused)
    }
}
#endif
