import AppKit

extension CmuxWebView {
    private static let semanticCopyLinkMenuItemIdentifier =
        NSUserInterfaceItemIdentifier("cmux.browser.semanticCopyLink")

    func insertSemanticCopyLinkContextMenuItemIfNeeded(to menu: NSMenu) {
        guard let url = capturedContextMenuLinkURLForCurrentMenu(),
              let copyValue = BrowserSemanticLinkCopyValue(linkURL: url),
              !menu.items.contains(where: { $0.identifier == Self.semanticCopyLinkMenuItemIdentifier }) else {
            return
        }

        let item = NSMenuItem(
            title: copyValue.menuTitle,
            action: #selector(contextMenuCopySemanticLinkValue(_:)),
            keyEquivalent: ""
        )
        item.identifier = Self.semanticCopyLinkMenuItemIdentifier
        item.representedObject = copyValue.string
        item.target = self
        menu.insertItem(item, at: semanticCopyLinkInsertionIndex(in: menu))
    }

    @objc func contextMenuCopySemanticLinkValue(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let value = item.representedObject as? String,
              !value.isEmpty else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    private func semanticCopyLinkInsertionIndex(in menu: NSMenu) -> Int {
        guard let copyLinkIndex = menu.items.firstIndex(where: {
            $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink"
        }) else {
            return menu.items.count
        }
        return min(copyLinkIndex + 1, menu.items.count)
    }
}
