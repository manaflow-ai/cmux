import AppKit

extension CmuxWebView {
    func appendSurfacePipContextMenuItem(to menu: NSMenu) {
        guard let panelId = contextMenuSurfacePipPanelId?(),
              let app = AppDelegate.shared else {
            return
        }
        if app.isSurfaceInPip(panelId: panelId) {
            appendSurfacePipMenuItem(
                to: menu,
                title: String(localized: "command.surfacePip.return.title", defaultValue: "Return Surface from Picture in Picture"),
                action: #selector(contextMenuReturnSurfacePictureInPicture(_:)),
                symbolName: "pip.exit"
            )
            return
        }
        guard app.canPopOutSurfacePip(panelId: panelId) else { return }
        appendSurfacePipMenuItem(
            to: menu,
            title: String(localized: "browser.contextMenu.surfacePip.pop", defaultValue: "Pop Out Surface (Picture in Picture)"),
            action: #selector(contextMenuPopOutSurfacePictureInPicture(_:)),
            symbolName: "pip.enter"
        )
    }

    private func appendSurfacePipMenuItem(
        to menu: NSMenu,
        title: String,
        action: Selector,
        symbolName: String
    ) {
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let item = NSMenuItem(
            title: title,
            action: action,
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        menu.addItem(item)
    }

    @objc func contextMenuPopOutSurfacePictureInPicture(_ sender: Any?) {
        _ = sender
        guard let panelId = contextMenuSurfacePipPanelId?(),
              case .success = AppDelegate.shared?.performSurfacePipAction(panelId: panelId, action: .pop) else {
            NSSound.beep()
            return
        }
    }

    @objc func contextMenuReturnSurfacePictureInPicture(_ sender: Any?) {
        _ = sender
        guard let panelId = contextMenuSurfacePipPanelId?(),
              case .success = AppDelegate.shared?.performSurfacePipAction(panelId: panelId, action: .return) else {
            NSSound.beep()
            return
        }
    }
}
