import AppKit

extension SidebarTabDragPayload {
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(
            "\(Self.prefix)\(tabId.uuidString)",
            forType: NSPasteboard.PasteboardType(Self.typeIdentifier)
        )
        return item
    }
}
