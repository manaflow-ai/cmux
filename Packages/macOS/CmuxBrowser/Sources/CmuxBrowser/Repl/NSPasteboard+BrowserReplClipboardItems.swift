public import AppKit
import UniformTypeIdentifiers

extension NSPasteboard {
    /// Writes a REPL tab's virtual clipboard items (`clipboard.write`:
    /// `{ type, base64 }`, MIME types or raw pasteboard types) to this
    /// pasteboard as one item, for WebKit's Paste to read.
    ///
    /// Items that refer to local files are left out: a file URL (also a
    /// `file:` URL given as `text/uri-list` or another URL type), a Finder
    /// filename list, an alias, a Finder node or a file promise. WebKit's
    /// trusted Paste turns those into `File` objects for the page, which
    /// would hand the page a file outside the session's file root.
    @MainActor
    public func writeBrowserReplClipboardItems(_ items: [[String: Any]]) {
        clearContents()
        let item = NSPasteboardItem()
        for entry in items {
            guard let type = entry["type"] as? String,
                  let base64 = entry["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { continue }
            let pasteboardType = Self.browserReplPasteboardType(forMIME: type)
            guard !Self.browserReplRefersToLocalFiles(pasteboardType, data: data) else { continue }
            item.setData(data, forType: pasteboardType)
        }
        if !(item.types.isEmpty) { writeObjects([item]) }
    }

    /// Whether `data` of `type` names a local file: the type is a file
    /// reference (file URL, filename list, alias, Finder node, file
    /// promise), or a URL type whose data holds a `file:` URL.
    static func browserReplRefersToLocalFiles(_ type: NSPasteboard.PasteboardType, data: Data) -> Bool {
        let name = type.rawValue.lowercased()
        let fileMarkers = ["file-url", "fileurl", "filename", "promise", "alias", "finder.node", "0x6675726c", "0x68667320"]
        if fileMarkers.contains(where: name.contains) { return true }
        if let uti = UTType(type.rawValue),
           uti.conforms(to: .fileURL) || uti.conforms(to: .aliasFile) || uti.conforms(to: .resolvable) {
            return true
        }
        let isURLType = name.contains("url") || UTType(type.rawValue)?.conforms(to: .url) == true
        guard isURLType else { return false }
        // A URL type holds one URL, a list of them or a property list of
        // them; any `file:` scheme in it counts.
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return text.contains("file:")
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
