import AppKit

/// A pasteboard double that exposes HTML only through the raw-data API.
final class DataOnlyHTMLPasteboard: NSPasteboard {
    private let htmlData: Data

    init(html: String) {
        htmlData = Data(html.utf8)
        super.init()
    }

    override var types: [NSPasteboard.PasteboardType]? { [.html] }

    override func string(
        forType dataType: NSPasteboard.PasteboardType
    ) -> String? {
        nil
    }

    override func data(
        forType dataType: NSPasteboard.PasteboardType
    ) -> Data? {
        dataType == .html ? htmlData : nil
    }
}
