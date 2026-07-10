import AppKit

extension GhosttyNSView {
    func appendSurfacePipContextMenuItem(to menu: NSMenu) {
        guard let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared else {
            return
        }
        if app.isSurfaceInPip(panelId: surfaceId) {
            appendSurfacePipMenuItem(
                to: menu,
                title: String(localized: "command.surfacePip.return.title", defaultValue: "Return Surface from Picture in Picture"),
                action: #selector(returnCurrentSurfacePictureInPicture(_:)),
                symbolName: "pip.exit"
            )
            return
        }
        guard app.canPopOutSurfacePip(panelId: surfaceId) else { return }
        appendSurfacePipMenuItem(
            to: menu,
            title: String(localized: "terminalContextMenu.surfacePip.pop", defaultValue: "Pop Out Surface (Picture in Picture)"),
            action: #selector(popOutCurrentSurfacePictureInPicture(_:)),
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

    @objc func popOutCurrentSurfacePictureInPicture(_ sender: Any?) {
        _ = sender
        guard let surfaceId = terminalSurface?.id,
              case .success = AppDelegate.shared?.performSurfacePipAction(panelId: surfaceId, action: .pop) else {
            NSSound.beep()
            return
        }
    }

    @objc func returnCurrentSurfacePictureInPicture(_ sender: Any?) {
        _ = sender
        guard let surfaceId = terminalSurface?.id,
              case .success = AppDelegate.shared?.performSurfacePipAction(panelId: surfaceId, action: .return) else {
            NSSound.beep()
            return
        }
    }
}
