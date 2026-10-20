import AppKit
import CmuxHomeCore

/// What the intake reads from a pasteboard: `NSPasteboard` (drop and
/// paste), or a value in tests (a ci-step mini has no pasteboard server).
protocol HomePasteboardContents {
    /// File URLs on the pasteboard, in order (empty when none).
    var fileURLs: [URL] { get }
    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string(forType type: NSPasteboard.PasteboardType) -> String?
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
/// itself), but only when there is no real text (rich text often carries a
/// picture of itself). A string that is only the picture's link (a browser's
/// Copy Image adds one) or blank is not text, so such a paste attaches the
/// picture. A lone link that comes with rich text but is not marked as a
/// URL (a spreadsheet cell) is text. Types follow `HomeComposerCheck`, the
/// data side's rule.
enum HomeAttachmentIntake {
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL] + pictureTypes
    /// Picture types a paste or drop may carry, in preference order.
    private static let pictureTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"), .tiff,
    ]

    /// Whether the pasteboard holds something the data side takes (types,
    /// file names and the plain string; no picture bytes read), so a drag
    /// shows "copy" only for what the drop will accept.
    static func offers(_ board: any HomePasteboardContents) -> Bool {
        if board.hasType([.fileURL]) { return board.fileURLs.contains(where: HomeComposerCheck.accepts) }
        return !hasText(board) && acceptedPictureType(board) != nil
    }

    static func inputs(from board: any HomePasteboardContents) -> [HomeDraftInput] {
        let urls = board.fileURLs
        if !urls.isEmpty { return urls.map { .file($0) } }
        guard !hasText(board), let type = acceptedPictureType(board), let data = board.data(forType: type) else { return [] }
        return [.data(data, typeIdentifier: type.rawValue)]
    }

    /// Whether the pasteboard carries text the person meant to paste: a
    /// string that is not blank and not just one link. Beside rich text
    /// (whose picture is of the text itself) a lone link counts as text
    /// unless the pasteboard also marks it as a URL, as a browser does.
    static func hasText(_ board: any HomePasteboardContents) -> Bool {
        guard board.hasType([.string]) else { return false }
        if board.hasType(richTextTypes) && !board.hasType([.URL]) { return true }
        let text = (board.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if text.contains(where: \.isWhitespace) { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else { return true }
        return !["http", "https", "file", "data", "blob"].contains(scheme)
    }

    /// Rich text types an app writes beside a picture of its own selection.
    private static let richTextTypes: [NSPasteboard.PasteboardType] = [
        .rtf, .rtfd, NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
    ]

    private static func acceptedPictureType(_ board: any HomePasteboardContents) -> NSPasteboard.PasteboardType? {
        pictureTypes.first { board.hasType([$0]) && HomeAttachmentPolicy.accepts(typeIdentifier: $0.rawValue) }
    }
}
