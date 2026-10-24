import AppKit
import CmuxHomeCore
import UniformTypeIdentifiers

/// What the intake reads from a pasteboard: `NSPasteboard` (drop and
/// paste), or a value in tests (a ci-step mini has no pasteboard server).
protocol HomePasteboardContents {
    /// File URLs on the pasteboard, in order (empty when none).
    var fileURLs: [URL] { get }
    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    func string(forType type: NSPasteboard.PasteboardType) -> String?
    /// A drag's file promises, in order (the screenshot thumbnail, Photos, a
    /// browser's picture): files the source writes only when the drop asks.
    var filePromises: [any HomeFilePromise] { get }
    /// The pasteboard's items, in order (several copied pictures; words beside
    /// files); empty when the board is its one item.
    var items: [any HomePasteboardContents] { get }
}

extension HomePasteboardContents {
    var filePromises: [any HomeFilePromise] { [] }
    var items: [any HomePasteboardContents] { [] }
}

/// A file a drag's source writes when the drop asks: `NSFilePromiseReceiver`
/// (or a value in tests: a ci-step mini has no pasteboard server). Asked on
/// the main thread; the files arrive on the queue given.
protocol HomeFilePromise: AnyObject {
    /// The promised files' type identifiers (one per file for a legacy promise).
    var fileTypes: [String] { get }
    /// Asks the source to write its files into `destinationDir`; `reader` runs on
    /// `operationQueue` once per file.
    func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any], operationQueue: OperationQueue,
                              reader: @escaping (URL, (any Error)?) -> Void)
}

extension NSFilePromiseReceiver: HomeFilePromise {}

extension NSPasteboard: HomePasteboardContents {
    var fileURLs: [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    func hasType(_ types: [NSPasteboard.PasteboardType]) -> Bool { availableType(from: types) != nil }

    var filePromises: [any HomeFilePromise] {
        readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    var items: [any HomePasteboardContents] { pasteboardItems ?? [] }
}

extension NSPasteboardItem: HomePasteboardContents {
    var fileURLs: [URL] {
        guard let link = string(forType: .fileURL), let url = URL(string: link), url.isFileURL else { return [] }
        return [url]
    }

    func hasType(_ wanted: [NSPasteboard.PasteboardType]) -> Bool { availableType(from: wanted) != nil }
}

/// What a pasteboard (drop or paste) offers as attachments: file URLs
/// first; on a drag, file promises next (the source's own file: a
/// screenshot thumbnail, Photos, a browser's picture; `HomePromisedFiles`
/// receives them off the main thread); else picture or PDF bytes the data
/// side takes (it converts TIFF and HEIF itself), but only when there is no
/// real text (rich text often carries a picture of itself). A string that is only the picture's link (a browser's
/// Copy Image adds one) or blank is not text, so such a paste attaches the
/// picture. A lone link that comes with rich text but is not marked as a
/// URL (a spreadsheet cell) is text. Types follow `HomeComposerCheck`, the
/// data side's rule.
enum HomeAttachmentIntake {
    /// The types Home's drop target registers. No plain string or bare link:
    /// a text or link drag keeps the field's own handling and the panes'
    /// link drop zones.
    static let dragTypes: [NSPasteboard.PasteboardType] = [.fileURL] + promiseTypes + pictureTypes
    /// File promise types, modern and legacy (`NSFilePromiseReceiver` reads both).
    static let promiseTypes: [NSPasteboard.PasteboardType] = NSFilePromiseReceiver.readableDraggedTypes.map {
        NSPasteboard.PasteboardType($0)
    } + [NSPasteboard.PasteboardType("Apple files promise pasteboard type")]
    /// Picture (and PDF) types a paste or drop may carry, in preference order:
    /// Preview's selection carries TIFF and PDF, a browser's picture its own bytes.
    private static let pictureTypes: [NSPasteboard.PasteboardType] = [
        .png, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("com.compuserve.gif"), NSPasteboard.PasteboardType("org.webmproject.webp"), .tiff, .pdf,
    ]

    /// Whether the pasteboard holds something the data side takes (types,
    /// file names and the plain string; no picture bytes read), so a drag
    /// shows "copy" only for what the drop will accept. `dragging` counts
    /// file promises (only a drop can ask a source to write its file).
    static func offers(_ board: any HomePasteboardContents, dragging: Bool = false) -> Bool {
        if board.hasType([.fileURL]) { return board.fileURLs.contains(where: HomeComposerCheck.accepts) }
        // A promise of a file, else the drag's own picture bytes (a browser's picture carries both; a
        // promise the drag can't read yet must not hide them).
        if dragging, board.hasType(promiseTypes), board.filePromises.contains(where: promisesAFile) { return true }
        return !hasText(board) && acceptedPictureType(board) != nil
    }

    /// The attachments a paste or drop gives, in order: its files; else, with no text, each
    /// item's picture (several pictures copied together all attach); else the pictures inside
    /// its rich text (a note's or a mail's), whose words paste beside them (``textBeside(_:)``).
    static func inputs(from board: any HomePasteboardContents) -> [HomeDraftInput] {
        let urls = board.fileURLs
        if !urls.isEmpty { return urls.map { .file($0) } }
        if hasText(board) { return richTextPictures(board) }
        let pictures = board.items.compactMap(picture)
        if !pictures.isEmpty { return pictures }
        return picture(board).map { [$0] } ?? []
    }

    /// The words a paste carries beside the attachments ``inputs(from:)`` takes, for the field to
    /// insert at the caret: the items with text and no file (a file's own item names it: not
    /// words), or the words around rich text's pictures without their U+FFFC marks; nil: none.
    static func textBeside(_ board: any HomePasteboardContents) -> String? {
        let text: String
        if !board.fileURLs.isEmpty {
            text = board.items.filter { $0.fileURLs.isEmpty && hasText($0) }.compactMap { $0.string(forType: .string) }
                .joined(separator: "\n")
        } else if hasText(board) {
            text = String((board.string(forType: .string) ?? "").unicodeScalars.filter { $0 != "\u{FFFC}" })
        } else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// One item's (or a whole board's) picture bytes, under the first type the data side takes.
    private static func picture(_ board: any HomePasteboardContents) -> HomeDraftInput? {
        guard let type = acceptedPictureType(board), let data = board.data(forType: type) else { return nil }
        return .data(data, typeIdentifier: type.rawValue)
    }

    /// The files inside a board's RTFD (Notes, TextEdit, Mail, Pages) the data side takes, in
    /// their order in the text; empty without RTFD.
    private static func richTextPictures(_ board: any HomePasteboardContents) -> [HomeDraftInput] {
        guard let data = board.data(forType: .rtfd), let rich = NSAttributedString(rtfd: data, documentAttributes: nil) else { return [] }
        var out: [HomeDraftInput] = []
        rich.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rich.length)) { value, _, _ in
            guard let wrapper = (value as? NSTextAttachment)?.fileWrapper, wrapper.isRegularFile,
                  let bytes = wrapper.regularFileContents,
                  let name = wrapper.preferredFilename ?? wrapper.filename,
                  let type = UTType(filenameExtension: (name as NSString).pathExtension),
                  HomeAttachmentPolicy.accepts(typeIdentifier: type.identifier) else { return }
            out.append(.data(bytes, typeIdentifier: type.identifier))
        }
        return out
    }

    /// A promise of at least one file the data side takes: not only folders (it takes any file).
    private static func promisesAFile(_ receiver: any HomeFilePromise) -> Bool {
        let types = receiver.fileTypes.compactMap { UTType($0) }
        return types.isEmpty || types.contains { !$0.conforms(to: .folder) && !$0.conforms(to: .directory) }
    }

    /// A drop's file promises when it has no file URLs (a file URL is the file
    /// itself, so it wins); empty otherwise.
    static func promises(from board: any HomePasteboardContents) -> [any HomeFilePromise] {
        guard !board.hasType([.fileURL]), board.hasType(promiseTypes) else { return [] }
        return board.filePromises.filter(promisesAFile)
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
