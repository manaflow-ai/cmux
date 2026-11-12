import AppKit
import CmuxHomeCore
import UniformTypeIdentifiers

/// One thing the user gave the composer: a file (drop, picker, a copied
/// file) or raw bytes with their type (a pasted screenshot).
enum ChiefDraftInput: Hashable {
    case file(URL)
    case data(Data, typeIdentifier: String)
}

/// What a pasteboard (drop or paste) offers as attachments, and the check
/// before preparing (cmux-next `HomeAttachmentIntake` and
/// `HomeComposerCheck`): file URLs first; else picture bytes, but only when
/// there is no text (rich text often carries a picture of itself). Types
/// follow `HomeAttachmentPolicy`, the data side's own rule, so paste, drop,
/// the drag check and the picker agree and a refused file is never copied.
enum ChiefAttachmentIntake {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL] + pictureTypes
    private static let pictureTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), .tiff,
    ]

    /// The types the file picker offers: exactly what the data side accepts.
    static var pickerTypes: [UTType] {
        HomeAttachmentPolicy.acceptedInputTypes.sorted().compactMap { UTType($0) }
    }

    static func fileURLs(_ board: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return board.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    /// Whether the pasteboard holds something the data side takes (types and
    /// names only; no bytes read).
    static func offers(_ board: NSPasteboard) -> Bool {
        if board.availableType(from: [.fileURL]) != nil {
            return fileURLs(board).contains(where: HomeAttachmentPolicy.accepts(fileURL:))
        }
        return board.availableType(from: [.string]) == nil && acceptedPictureType(board) != nil
    }

    static func inputs(from board: NSPasteboard) -> [ChiefDraftInput] {
        let urls = fileURLs(board)
        if !urls.isEmpty { return urls.map { .file($0) } }
        guard board.availableType(from: [.string]) == nil, let type = acceptedPictureType(board),
              let data = board.data(forType: type) else { return [] }
        return [.data(data, typeIdentifier: type.rawValue)]
    }

    private static func acceptedPictureType(_ board: NSPasteboard) -> NSPasteboard.PasteboardType? {
        pictureTypes.first { board.availableType(from: [$0]) != nil && HomeAttachmentPolicy.accepts(typeIdentifier: $0.rawValue) }
    }

    /// Nil when the input may be attached, else the notice that says why not.
    static func refusal(for input: ChiefDraftInput) -> String? {
        let name: String, accepted: Bool, size: Int, typeName: String
        switch input {
        case .file(let url):
            // A stat for the size only; the bytes are read by the data side.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            name = url.lastPathComponent
            accepted = HomeAttachmentPolicy.accepts(fileURL: url)
            size = values?.fileSize ?? 0
            typeName = url.pathExtension
        case .data(let data, let identifier):
            name = ChiefStrings.pastedItem
            accepted = HomeAttachmentPolicy.accepts(typeIdentifier: identifier)
            size = data.count
            typeName = identifier
        }
        guard accepted else { return ChiefStrings.attachmentRefusal(.typeRefused(mimeType: typeName, name: name), name: name) }
        if size > HomeAttachmentPolicy.maxBytes {
            return ChiefStrings.attachmentRefusal(.tooLarge(byteCount: size, limit: HomeAttachmentPolicy.maxBytes), name: name)
        }
        if size == 0 { return ChiefStrings.attachmentRefusal(.empty(name: name), name: name) }
        return nil
    }
}
