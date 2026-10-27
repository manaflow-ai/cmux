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
        let done: (Int?) -> Void = { [weak self, weak tab] id in
            self?.answerContextMenu(token, browser: browser, tab: tab, command: id)
        }
        guard tab.delegate != nil else {
            let request = BrowserContextMenuRequest(items: all, target: target, location: location, completion: done)
            return tab.host.contextMenus.present(request, in: tab.contentView)
        }
        let emit: (BrowserContextMenuTarget) -> Void = { [weak tab] target in
            // The page lost its browser while cmux read the link's text: no menu for it.
            guard let tab, tab.browserID == browser else { return done(nil) }
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

    /// Ends CONTEXT_MENU `token` with the chosen command (nil: none): in its event's turn, or later for a
    /// page that still has the menu's browser (``answerContextMenu(_:browser:tab:command:)``). A post:
    /// nothing to read back.
    func finishContextMenu(_ token: Int32, command: Int?) {
        shim?.contextMenuDone(token, Int32(command ?? -1), 0)
    }

    /// The menu of `browser`, shown for `tab`, closed in a later turn. In host mode the answer goes only
    /// while the page still has that browser here: a token numbers a menu of the host that sent it, the
    /// next host numbers its own from 1 again (CEFShim's StoreMenuCallback), so an old token there would
    /// end another page's menu. A page whose browser closed or ended with its host has no menu left to
    /// end, as Chrome's RenderViewContextMenu goes with its WebContents (CEF's CefMenuManager::Destroy
    /// ends a closed browser's menu). In process the shim is the same for the life of the app.
    func answerContextMenu(_ token: Int32, browser: Int32, tab: CEFTab?, command: Int?) {
        guard hostStart == nil || (tab != nil && tabsByBrowser[browser] === tab) else { return }
        finishContextMenu(token, command: command)
    }
}
