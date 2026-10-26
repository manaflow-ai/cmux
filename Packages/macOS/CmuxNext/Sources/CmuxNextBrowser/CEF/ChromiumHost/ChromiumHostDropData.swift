import AppKit

/// What a drag carries into a hosted page, read once from its pasteboard when it enters (a pasteboard
/// read per move lags), as Chrome's `PopulateDropDataFromPasteboard` fills a `DropData`
/// (content/browser/web_contents/web_drag_dest_mac.mm): the files as absolute paths, the plain
/// text, and the first URL that is not a file's, with its title.
nonisolated struct ChromiumHostDropData: Equatable, Sendable {
    var files: [String] = []
    var text: String?
    var url: String?
    var urlTitle: String?

    /// The pasteboard types a page takes drags of.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]
    /// A dragged link's title (`public.url-name`, which Chrome reads for `DropData::url_title`).
    static let urlNameType = NSPasteboard.PasteboardType("public.url-name")

    /// Nothing a page can take.
    var isEmpty: Bool { files.isEmpty && text == nil && url == nil }

    init(files: [String] = [], text: String? = nil, url: String? = nil, urlTitle: String? = nil) {
        (self.files, self.text, self.url, self.urlTitle) = (files, text, url, urlTitle)
    }

    @MainActor init(pasteboard: NSPasteboard) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
        files = urls.filter(\.isFileURL).map(\.path)
        if let link = urls.first(where: { !$0.isFileURL }) {
            url = link.absoluteString
            urlTitle = pasteboard.string(forType: Self.urlNameType)
        }
        text = pasteboard.string(forType: .string)
    }
}

/// A point in a hosted page view: points from its top left, the page's DIP (the DragTarget calls' x, y).
nonisolated struct ChromiumHostDragPoint: Equatable, Sendable {
    var x: Int32
    var y: Int32

    /// `point` in a view `height` points tall whose origin is at the bottom left.
    init(unflipped point: CGPoint, height: CGFloat) {
        x = Int32(point.x.rounded(.down))
        y = Int32((height - point.y).rounded(.down))
    }

    init(x: Int32, y: Int32) {
        (self.x, self.y) = (x, y)
    }
}

/// One DragTarget call for a page's browser (`cmux_shim_browser_drag_target_*`). `allowed` is the
/// drag source's `cef_drag_operations_mask_t` (NSDragOperation's own bits: 1 copy, 2 link, 16 move);
/// `modifiers` are `cef_event_flags_t`.
nonisolated enum ChromiumHostDragEvent: Equatable, Sendable {
    case enter(ChromiumHostDropData, ChromiumHostDragPoint, allowed: Int32, modifiers: Int32)
    case over(ChromiumHostDragPoint, allowed: Int32, modifiers: Int32)
    case leave
    case drop(ChromiumHostDragPoint, modifiers: Int32)
}
