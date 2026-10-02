import AppKit
import Foundation

extension CEFRuntime {
    func showContextMenu(browser: Int32, token: Int32, x: Int, y: Int, itemsJSON: String, paramsJSON: String) {
        guard let tab = tabsByBrowser[browser] else {
            shim?.contextMenuDone(token, -1, 0)
            return
        }
        let request = BrowserContextMenuRequest(
            items: BrowserContextMenuItem.decodeList(itemsJSON),
            target: BrowserContextMenuTarget.decode(paramsJSON),
            location: CGPoint(x: x, y: y)
        ) { [weak self] id in
            self?.shim?.contextMenuDone(token, Int32(id ?? -1), 0)
        }
        if tab.delegate == nil {
            tab.host.contextMenus.present(request, in: tab.contentView)
        } else {
            tab.emit(.contextMenu(request))
        }
    }
}
