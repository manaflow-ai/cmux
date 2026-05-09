import AppKit

extension GhosttyNSView {
    func appendMoveCurrentSurfaceToNewWorkspaceMenuItem(to menu: NSMenu) {
        guard canMoveCurrentSurfaceToNewWorkspace() else { return }

        menu.addItem(.separator())
        let item = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.moveTabToNewWorkspace", defaultValue: "Move Tab to New Workspace"),
            action: #selector(moveCurrentSurfaceToNewWorkspace(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.image = NSImage(
            systemSymbolName: "rectangle.portrait.and.arrow.right",
            accessibilityDescription: nil
        )
    }

    private func canMoveCurrentSurfaceToNewWorkspace() -> Bool {
        guard let surfaceId = terminalSurface?.id else { return false }
        return AppDelegate.shared?.canMoveSurfaceToNewWorkspace(panelId: surfaceId) ?? false
    }

    @objc func moveCurrentSurfaceToNewWorkspace(_ sender: Any?) {
        guard let surfaceId = terminalSurface?.id,
              AppDelegate.shared?.moveSurfaceToNewWorkspace(
                panelId: surfaceId,
                focus: true,
                focusWindow: false
              ) != nil else {
            NSSound.beep()
            return
        }
    }
}
