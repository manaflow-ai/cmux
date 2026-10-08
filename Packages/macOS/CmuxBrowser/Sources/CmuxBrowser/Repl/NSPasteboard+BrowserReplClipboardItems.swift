public import AppKit
import UniformTypeIdentifiers

extension NSPasteboard {
    /// Writes a REPL tab's virtual clipboard items (`clipboard.write`:
    /// `{ type, base64 }`, MIME types or raw pasteboard types) to this
    /// pasteboard as one item, for WebKit's Paste to read.
    ///
    /// Only the types the virtual clipboard needs are written (an
    /// allowlist): plain text, HTML, RTF, PNG, TIFF, WebKit's custom web
    /// data, and a URL whose every entry is `http:` or `https:`. WebKit's
    /// trusted Paste turns a file reference (a file URL, a Finder filename
    /// list, an alias, a file promise, RTFD attachments) into `File`
    /// objects for the page, which would hand the page a file outside the
    /// session's file root, and a denylist of names or a scan for `file:`
    /// misses encodings (UTF-16, binary property lists, raw type names).
    @MainActor
    public func writeBrowserReplClipboardItems(_ items: [[String: Any]]) {
        clearContents()
        let item = NSPasteboardItem()
        for entry in items {
            guard let type = entry["type"] as? String,
                  let base64 = entry["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { continue }
            let pasteboardType = Self.browserReplPasteboardType(forMIME: type)
            guard Self.browserReplMayPaste(pasteboardType, data: data) else { continue }
            item.setData(data, forType: pasteboardType)
        }
        if !(item.types.isEmpty) { writeObjects([item]) }
    }

    /// The types a tab's clipboard may put on the pasteboard WebKit pastes from.
    static let browserReplPastableTypes: Set<NSPasteboard.PasteboardType> = [
        .string, .html, .rtf, .png, .tiff,
        NSPasteboard.PasteboardType("com.apple.WebKit.custom-pasteboard-data"),
    ]

    /// Whether `data` of `type` may be pasted: an allowed type, or a URL
    /// whose every entry (a `text/uri-list`, comment lines aside) is an
    /// `http:` or `https:` URL in UTF-8.
    static func browserReplMayPaste(_ type: NSPasteboard.PasteboardType, data: Data) -> Bool {
        if browserReplPastableTypes.contains(type) { return true }
        guard type == .URL, let text = String(data: data, encoding: .utf8) else { return false }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy { line in
            guard line.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }),
                  let url = URL(string: line), let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false else { return false }
            return scheme == "http" || scheme == "https"
        }
    }

    private static func browserReplPasteboardType(forMIME mime: String) -> NSPasteboard.PasteboardType {
        switch mime.lowercased() {
        case "text/plain": return .string
        case "text/html": return .html
        case "text/rtf", "application/rtf": return .rtf
        case "text/uri-list": return .URL
        case "image/png": return .png
        case "image/tiff": return .tiff
        default:
            if !mime.contains("/") { return NSPasteboard.PasteboardType(mime) }
            if let type = UTType(mimeType: mime), !type.isDynamic { return NSPasteboard.PasteboardType(type.identifier) }
            return NSPasteboard.PasteboardType(mime)
        }
    }
}
