import AppKit
import CmuxHomeCore

/// What the intake reads from a pasteboard: `NSPasteboard` (drop and
/// paste), or a value in tests (a ci-step mini has no pasteboard server).
protocol HomePasteboardContents {
    /// File URLs on the pasteboard, in order (empty when none).
    var fileURLs: [URL] { get }
    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: HomePasteboardContents {
    var fileURLs: [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool { availableType(from: types) != nil }
}

/// What a pasteboard (drop or paste) offers as attachments: file URLs
/// first; else picture bytes the data side takes (it converts TIFF and HEIF
/// itself), but only when there is no text (rich text often carries a
/// picture of itself). Types follow `HomeComposerCheck`, the data side's rule.
enum HomeAttachmentIntake {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL] + pictureTypes
    /// Picture types a paste or drop may carry, in preference order.
    private static let pictureTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), .tiff,
    ]

    /// Whether the pasteboard holds something the data side takes (types
    /// and file names only, no bytes read), so a drag shows "copy" only for
    /// what the drop will accept.
    static func offers(_ board: any HomePasteboardContents) -> Bool {
        if board.hasType([.fileURL]) { return board.fileURLs.contains(where: HomeComposerCheck.accepts) }
        return !board.hasType([.string]) && acceptedPictureType(board) != nil
    }

    static func inputs(from board: any HomePasteboardContents) -> [HomeDraftInput] {
        let urls = board.fileURLs
        if !urls.isEmpty { return urls.map { .file($0) } }
        guard !board.hasType([.string]), let type = acceptedPictureType(board), let data = board.data(forType: type) else { return [] }
        return [.data(data, typeIdentifier: type.rawValue)]
    }

    private static func acceptedPictureType(_ board: any HomePasteboardContents) -> NSPasteboard.PasteboardType? {
        pictureTypes.first { board.hasType([$0]) && HomeAttachmentPolicy.accepts(typeIdentifier: $0.rawValue) }
    }
}
