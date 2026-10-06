import AppKit
import Foundation

extension CEFRuntime {
    /// Chromium's page menu. A tab with a host gets the model without the
    /// link, image and selection rows (the host shows the cmux rows for
    /// them, the same in both engines) and with the link's text, which
    /// Chromium does not report. A tab without a host shows Chromium's own
    /// model.
    func showContextMenu(browser: Int32, token: Int32, x: Int, y: Int, itemsJSON: String, paramsJSON: String) {
        guard let tab = tabsByBrowser[browser] else {
            shim?.contextMenuDone(token, -1, 0)
            return
        }
        let all = BrowserContextMenuItem.decodeList(itemsJSON)
        let target = BrowserContextMenuTarget.chromium(paramsJSON)
        let location = CGPoint(x: x, y: y)
        let done: (Int?) -> Void = { [weak self] id in self?.shim?.contextMenuDone(token, Int32(id ?? -1), 0) }
        guard tab.delegate != nil else {
            let request = BrowserContextMenuRequest(items: all, target: target, location: location, completion: done)
            return tab.host.contextMenus.present(request, in: tab.contentView)
        }
        let emit: (BrowserContextMenuTarget) -> Void = { [weak tab] target in
            guard let tab else { return done(nil) }
            tab.emit(.contextMenu(BrowserContextMenuRequest(
                items: BrowserContextMenuItem.withoutHitItems(all, for: target), target: target, location: location,
                completion: done
            )))
        }
        guard let link = target.linkURL else { return emit(target) }
        Task { @MainActor [weak tab] in
            var target = target
            if let tab { target.linkText = await CEFLinkText.text(for: link, in: tab) }
            emit(target)
        }
    }
}
