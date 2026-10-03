public import AppKit
import UniformTypeIdentifiers

extension NSPasteboard {
    /// Writes a REPL tab's virtual clipboard items (`clipboard.write`:
    /// `{ type, base64 }`, MIME types or raw pasteboard types) to this
    /// pasteboard as one item, for WebKit's Paste to read.
    @MainActor
    public func writeBrowserReplClipboardItems(_ items: [[String: Any]]) {
        clearContents()
        let item = NSPasteboardItem()
        for entry in items {
            guard let type = entry["type"] as? String,
                  let base64 = entry["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { continue }
            item.setData(data, forType: Self.browserReplPasteboardType(forMIME: type))
        }
        if !(item.types.isEmpty) { writeObjects([item]) }
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
