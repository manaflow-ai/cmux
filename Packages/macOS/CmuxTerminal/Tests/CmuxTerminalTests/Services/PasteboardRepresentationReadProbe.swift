import AppKit

/// Records which lazy rich representations a pasteboard consumer requests.
final class PasteboardRepresentationReadProbe: NSObject, NSPasteboardItemDataProvider {
    private(set) var requestedTypes: [NSPasteboard.PasteboardType] = []

    func reset() {
        requestedTypes.removeAll()
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestedTypes.append(type)
        let data: Data
        switch type {
        case .html:
            data = Data("<b>hard<br>wrapped</b>".utf8)
        case .rtf:
            data = Data("{\\rtf1\\ansi hard\\line wrapped}".utf8)
        default:
            data = Data("stale attachment payload".utf8)
        }
        item.setData(data, forType: type)
    }
}
