import AppKit
import Foundation

extension CEFRuntime {
    /// Chromium's page menu. A tab with a host gets the model without the
    /// link, image and selection rows (the host shows the cmux rows for
    /// them, the same in both engines) and with the link's text, which
    /// Chromium does not report. A tab without a host shows Chromium's own
    /// model.
    func showContextMenu(browser: Int32, token: Int32, x: Int, y: Int, itemsJSON: String, paramsJSON: String) {
        guard let tab = tabsByBrowser[browser] else { return finishContextMenu(token, command: nil) }
        // Host mode: the menu's Inspect opens DevTools in the host, so its placement goes first.
        tab.devToolsController.pageMenuWillShow()
        let all = extensionStores.withRowIcons(BrowserContextMenuItem.decodeList(itemsJSON), profile: tab.profileID)
        let target = BrowserContextMenuTarget.chromium(paramsJSON)
        let location = CGPoint(x: x, y: y)
        let done: (Int?) -> Void = { [weak self] id in self?.finishContextMenu(token, command: id) }
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

    /// Ends CONTEXT_MENU `token` with the chosen command (nil: none). A post: nothing to read back.
    func finishContextMenu(_ token: Int32, command: Int?) {
        shim?.contextMenuDone(token, Int32(command ?? -1), 0)
    }
}
