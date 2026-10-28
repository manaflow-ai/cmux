import AppKit
import UniformTypeIdentifiers

/// What a terminal paste can deliver, read from a pasteboard once: the paste
/// decisions (file paths first, then text, then URLs, then a saved image) run
/// on this value, so tests need no pasteboard server.
struct TerminalPasteboardContents: Sendable, Equatable {
    /// File URLs (Finder copies), pasted as shell-escaped paths.
    var fileURLs: [URL] = []
    /// Plain text.
    var string: String?
    /// Other URLs, pasted as their absolute strings.
    var urls: [URL] = []
    /// PNG bytes, saved as is.
    var png: Data?
    /// JPEG bytes, saved as is.
    var jpeg: Data?
    /// Any other image the pasteboard renders as TIFF (screenshots), saved as PNG.
    var tiff: Data?

    /// Whether an image is present (PNG, JPEG or TIFF bytes).
    var hasImage: Bool {
        [png, jpeg, tiff].contains { !($0?.isEmpty ?? true) }
    }
}

extension TerminalPasteboardContents {
    /// Reads every type a paste uses. Image bytes are read only when the
    /// pasteboard holds no text to paste, since text always wins.
    init(pasteboard: NSPasteboard) {
        fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        string = pasteboard.string(forType: .string)
        urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard TerminalPasteboard.pasteText(from: self)?.isEmpty ?? true else { return }
        png = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        jpeg = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier))
        if png == nil, jpeg == nil, pasteboard.canReadObject(forClasses: [NSImage.self], options: nil) {
            tiff = NSImage(pasteboard: pasteboard)?.tiffRepresentation
        }
    }
}
