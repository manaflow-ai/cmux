import AppKit
import CmuxNextCompat
import UniformTypeIdentifiers

/// A drag a Chromium page started: the fork's `cmux_drag_source_t` (include/cef_cmux.h, API 30), copied out
/// during the shim's drag callback (task p01-process-051 of plans/cmux-next/chrome-parity/p01-process.md).
///
/// In host mode cmux's page view starts the `NSDraggingSession` with it, as Chrome's app shim view starts one
/// with the `DropData` its browser process sends (content/app_shim_remote_cocoa/web_contents_view_cocoa.mm,
/// `-startDragWithDropData:`). The pasteboard holds what Chrome's `WebDragSource` writes
/// (content/app_shim_remote_cocoa/web_drag_source_mac.mm): the link as a URL with its title, the text, the
/// HTML, and a dragged file (an image) as a file promise the drop target writes, off the main thread.
nonisolated struct CEFPageDragData: Equatable, Sendable {
    /// What the page allows: copy, link and move only (`blink::DragOperationsMask`'s NSDragOperation bits).
    var allowedOperations: NSDragOperation
    var url: String
    var urlTitle: String
    var text: String
    var html: String
    var htmlBaseURL: String
    /// A dragged file's bytes (an image), its suggested name and the URL it came from.
    var fileContents: Data
    var fileName: String
    var fileSourceURL: String
    /// The drag image as PNG, `imageScale` pixels per point, and the pointer's offset from its top left.
    var imagePNG: Data
    var imageScale: Double
    var cursorOffset: CGPoint

    /// The fork struct's byte offsets on LP64. `ForkDragSource` in ChromiumHost/src/host_drag.h asserts the
    /// same ones; scripts/cmux-next/tests/chromium-host-dispatch.test.sh compares the two lists.
    nonisolated enum Offset {
        static let size = 120
        static let allowedOperations = 4
        static let url = 8
        static let urlTitle = 16
        static let text = 24
        static let html = 32
        static let htmlBaseUrl = 40
        static let fileContents = 48
        static let fileContentsLength = 56
        static let fileName = 64
        static let fileContentsSourceUrl = 72
        static let downloadMetadata = 80
        static let imagePng = 88
        static let imagePngLength = 96
        static let imageScale = 104
        static let cursorOffsetX = 112
        static let cursorOffsetY = 116
    }

    /// The operations a page may allow.
    static let pageOperations: NSDragOperation = [.copy, .link, .move]

    init(allowedOperations: NSDragOperation, url: String = "", urlTitle: String = "", text: String = "", html: String = "",
         htmlBaseURL: String = "", fileContents: Data = Data(), fileName: String = "", fileSourceURL: String = "",
         imagePNG: Data = Data(), imageScale: Double = 1, cursorOffset: CGPoint = .zero) {
        self.allowedOperations = allowedOperations.intersection(Self.pageOperations)
        self.url = url
        self.urlTitle = urlTitle
        self.text = text
        self.html = html
        self.htmlBaseURL = htmlBaseURL
        self.fileContents = fileContents
        self.fileName = fileName
        self.fileSourceURL = fileSourceURL
        self.imagePNG = imagePNG
        self.imageScale = imageScale.isFinite && imageScale > 0 ? imageScale : 1
        self.cursorOffset = cursorOffset
    }

    /// The drag behind the fork's pointer, valid only during the callback; nil for a struct older than API 30's.
    init?(fork drag: UnsafeRawPointer) {
        guard Int(drag.load(as: Int32.self)) >= Offset.size else { return nil }
        func int(_ offset: Int) -> Int32 { drag.load(fromByteOffset: offset, as: Int32.self) }
        func string(_ offset: Int) -> String {
            drag.load(fromByteOffset: offset, as: UnsafePointer<CChar>?.self).map { String(cString: $0) } ?? ""
        }
        func bytes(_ offset: Int, length: Int) -> Data {
            let count = Int(int(length))
            guard count > 0, let base = drag.load(fromByteOffset: offset, as: UnsafeRawPointer?.self) else { return Data() }
            return Data(bytes: base, count: count)
        }
        self.init(allowedOperations: NSDragOperation(rawValue: UInt(UInt32(bitPattern: int(Offset.allowedOperations)))),
                  url: string(Offset.url), urlTitle: string(Offset.urlTitle), text: string(Offset.text),
                  html: string(Offset.html), htmlBaseURL: string(Offset.htmlBaseUrl),
                  fileContents: bytes(Offset.fileContents, length: Offset.fileContentsLength),
                  fileName: string(Offset.fileName), fileSourceURL: string(Offset.fileContentsSourceUrl),
                  imagePNG: bytes(Offset.imagePng, length: Offset.imagePngLength),
                  imageScale: drag.load(fromByteOffset: Offset.imageScale, as: Double.self),
                  cursorOffset: CGPoint(x: Int(int(Offset.cursorOffsetX)), y: Int(int(Offset.cursorOffsetY))))
    }

    /// The pasteboard types and strings the drag carries besides a file, `marker` (the page view's own type,
    /// which names a drag of this page) included. A link is also its text when the page dragged none, as
    /// Chrome writes it, so a terminal or a text field gets the URL.
    func strings(marker: NSPasteboard.PasteboardType) -> [NSPasteboard.PasteboardType: String] {
        var strings: [NSPasteboard.PasteboardType: String] = [marker: "1"]
        if !url.isEmpty, URL(string: url)?.scheme != nil {
            strings[.URL] = url
            // The link name Safari, Chrome and Finder read (BrowserURLDragItem.urlNameType).
            if !urlTitle.isEmpty { strings[NSPasteboard.PasteboardType("public.url-name")] = urlTitle }
        }
        if !text.isEmpty {
            strings[.string] = text
        } else if strings[.URL] != nil {
            strings[.string] = url
        }
        if !html.isEmpty { strings[.html] = html }
        return strings
    }

    /// The drag's one pasteboard writer: a file promise that also carries ``strings(marker:)`` when the page
    /// dragged a file, else one item with them.
    func pasteboardWriter(marker: NSPasteboard.PasteboardType) -> any NSPasteboardWriting {
        let strings = strings(marker: marker)
        guard !fileContents.isEmpty else {
            let item = NSPasteboardItem()
            for (type, value) in strings { item.setString(value, forType: type) }
            return item
        }
        let writer = CEFPageDragFileWriter(contents: fileContents, name: promisedFileName)
        return CEFPageDragFilePromise(writer: writer, fileType: promisedFileType.identifier, strings: strings)
    }

    /// The dropped file's name: the page's suggestion as one plain name, else the last part of its URL.
    var promisedFileName: String {
        for candidate in [fileName, URL(string: fileSourceURL)?.lastPathComponent ?? "", URL(string: url)?.lastPathComponent ?? ""] {
            let leaf = (candidate as NSString).lastPathComponent
            if !leaf.isEmpty, leaf != ".", leaf != "..", leaf != "/" { return leaf }
        }
        return "download"
    }

    /// The promised file's type, from its name; plain data when the name says none.
    var promisedFileType: UTType {
        UTType(filenameExtension: (promisedFileName as NSString).pathExtension) ?? .data
    }

    /// The operation to offer while the drag is over its own page and the page has not answered: the
    /// first of copy, link and move it allows, the HTML drag-and-drop default for an unset drop effect.
    var preferredOperation: NSDragOperation {
        for operation in [NSDragOperation.copy, .link, .move] where allowedOperations.contains(operation) { return operation }
        return []
    }
}

/// A dragged file the drop target asked for, written on the promise's own queue, never on the main thread.
nonisolated final class CEFPageDragFileWriter: NSObject, NSFilePromiseProviderDelegate {
    let contents: Data
    let name: String
    /// Serial, user-initiated: the person waits for the dropped file (plans/cmux-next/threading-model.md).
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.cmuxterm.next.browser.page-drag-file"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(contents: Data, name: String) {
        self.contents = contents
        self.name = name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        name
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        do {
            try contents.blockingWrite(to: url, options: .withoutOverwriting)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }
}

/// A file promise that also carries the drag's URL, text and HTML, so one dragged image is the file in Finder
/// and its URL in a terminal, as Chrome's single drag pasteboard is.
nonisolated final class CEFPageDragFilePromise: NSFilePromiseProvider {
    /// Kept here: the provider holds its delegate weakly.
    private let writer: CEFPageDragFileWriter
    private let strings: [NSPasteboard.PasteboardType: String]

    init(writer: CEFPageDragFileWriter, fileType: String, strings: [NSPasteboard.PasteboardType: String]) {
        self.writer = writer
        self.strings = strings
        super.init()
        self.fileType = fileType
        delegate = writer
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + strings.keys.sorted { $0.rawValue < $1.rawValue }
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        strings[type] ?? super.pasteboardPropertyList(forType: type)
    }
}
