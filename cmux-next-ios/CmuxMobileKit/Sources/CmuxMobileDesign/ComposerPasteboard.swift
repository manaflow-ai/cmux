#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// A file pasted into a composer, read once the person chose Paste.
public struct ComposerPastedFile: Sendable {
    public let data: Data?
    public let fileURL: URL
    public let byteCount: Int
    /// The copying app's name for it (Files: the file's name), with its extension.
    public let name: String
    public let type: UTType
}

/// Copied files read for a paste, and the ones that could not be attached.
public struct ComposerPastedFiles: Sendable {
    public var files: [ComposerPastedFile] = []
    /// Offered but unreadable.
    public var unreadable: [String] = []
}

/// What a composer's Paste takes from the pasteboard. Only types are read
/// (no "Allow Paste" prompt); the composer reads the data once the person
/// chose Paste.
public extension UIPasteboard {
    /// An image or a copied file leads the pasteboard: Paste attaches it.
    /// Text that came with an image (cells from Numbers, a note with a
    /// picture) still pastes as text, as the copying app put it first.
    var composerPastesAttachments: Bool {
        // An image copied as an image object (Photos, Safari) leads with
        // UIKit's private `com.apple.uikit.image`, not an image type.
        if hasImages, !hasStrings { return true }
        guard let first = composerLeadingType else { return hasImages }
        if first.conforms(to: .fileURL) { return true }
        if first.conforms(to: .image) { return hasImages || Self.isComposerFileType(first) }
        guard !hasStrings else { return false }
        return contains(pasteboardTypes: [UTType.fileURL.identifier]) || Self.isComposerFileType(first)
    }

    /// The pasteboard holds a copied file's own bytes (Files' Copy puts the
    /// file, not its path), not an image UIKit decodes or text.
    var composerHoldsFileData: Bool {
        guard !hasImages, let first = composerLeadingType, Self.isComposerFileType(first) else { return false }
        return !hasStrings || first.conforms(to: .image)
    }

    /// The first declared type, past an app's private ones: Files leads with
    /// `com.apple.DocumentManager.FINode.File`, then the file's own type
    /// (`com.adobe.pdf`). Nil when every type is private.
    var composerLeadingType: UTType? {
        types.lazy.compactMap { UTType($0) }.first(where: \.isDeclared)
    }

    /// A copied file's own type (a PDF, an archive, a movie, an SVG from
    /// Files or Mail): declared, and not text, rich text, a web page or link,
    /// or an app's private format.
    static func isComposerFileType(_ type: UTType) -> Bool {
        guard type.isDeclared, !type.isDynamic else { return false }
        if type.conforms(to: .image) { return true }
        let prose: [UTType] = [.text, .url, .rtfd, .flatRTFD, .webArchive]
        if prose.contains(where: { type.conforms(to: $0) }) { return false }
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
}

public extension ComposerPastedFiles {
    /// Reads the copied files of `providers` (take them from the pasteboard
    /// during the paste). Each arrives as a file the system wrote; it is copied while the provider grants access, off the main thread.
    @MainActor
    static func load(_ providers: [NSItemProvider]) async -> ComposerPastedFiles {
        var result = ComposerPastedFiles()
        for provider in providers {
            guard let type = provider.registeredTypeIdentifiers.lazy.compactMap({ UTType($0) })
                .first(where: { UIPasteboard.isComposerFileType($0) }) else { continue }
            let name = fileName(provider.suggestedName, type: type)
            let read: Read = await withCheckedContinuation { continuation in
                _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                    continuation.resume(returning: Read(url, name: name, inlineLimit: type.conforms(to: .image) ? 24 << 20 : ComposerFileCopy.inlineBytes))
                }
            }
            switch read {
            case .file(let copy): result.files.append(ComposerPastedFile(data: copy.inlineData, fileURL: copy.url, byteCount: copy.byteCount, name: name, type: type))
            case .unreadable: result.unreadable.append(name)
            }
        }
        return result
    }

    /// The copying app's name, safe as a file name, with the type's extension.
    static func fileName(_ suggested: String?, type: UTType) -> String {
        var name = (suggested ?? "").replacingOccurrences(of: "/", with: "-")
        if name.isEmpty || name == "." || name == ".." { name = String(localized: "Pasted file") }
        if let ext = type.preferredFilenameExtension, (name as NSString).pathExtension.isEmpty { name += ".\(ext)" }
        return name
    }

    private enum Read: Sendable {
        case file(ComposerFileCopy), unreadable

        /// Called on the provider's queue, while `url` still exists.
        init(_ url: URL?, name: String, inlineLimit: Int) {
            guard let url, let copy = try? ComposerFileCopy(source: url, name: name, inlineLimit: inlineLimit) else { self = .unreadable; return }
            self = .file(copy)
        }
    }
}
#endif
