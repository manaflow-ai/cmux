import AppKit

extension GhosttyNSView {
    func appendMoveCurrentSurfaceMoveMenuItems(to menu: NSMenu) {
        let canMoveToNewWorkspace = canMoveCurrentSurfaceToNewWorkspace()
        let workspaceTargets = currentSurfaceWorkspaceMoveTargets()
        guard canMoveToNewWorkspace || !workspaceTargets.isEmpty else { return }

        menu.addItem(.separator())
        if workspaceTargets.isEmpty {
            appendMoveCurrentSurfaceToNewWorkspaceMenuItem(to: menu)
            return
        }

        let moveItem = NSMenuItem(
            title: String(localized: "terminalContextMenu.moveTab", defaultValue: "Move Tab"),
            action: nil,
            keyEquivalent: ""
        )
        moveItem.image = NSImage(
            systemSymbolName: "rectangle.stack.badge.play",
            accessibilityDescription: nil
        )
        let submenu = NSMenu()
        if canMoveToNewWorkspace {
            appendMoveCurrentSurfaceToNewWorkspaceMenuItem(to: submenu)
            submenu.addItem(.separator())
        }

        for target in workspaceTargets {
            let item = NSMenuItem(
                title: target.label,
                action: #selector(moveCurrentSurfaceToWorkspace(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = target.workspaceId
            item.image = NSImage(
                systemSymbolName: "rectangle.portrait.on.rectangle.portrait",
                accessibilityDescription: nil
            )
            submenu.addItem(item)
        }
        moveItem.submenu = submenu
        menu.addItem(moveItem)
    }

    private func appendMoveCurrentSurfaceToNewWorkspaceMenuItem(to menu: NSMenu) {
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

    private func currentSurfaceWorkspaceMoveTargets() -> [AppDelegate.WorkspaceMoveTarget] {
        guard let surfaceId = terminalSurface?.id,
              let app = AppDelegate.shared else {
            return []
        }
        return app.workspaceMoveTargets(forSurface: surfaceId)
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

    @objc func moveCurrentSurfaceToWorkspace(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let workspaceId = item.representedObject as? UUID,
              let surfaceId = terminalSurface?.id,
              AppDelegate.shared?.moveSurface(
                panelId: surfaceId,
                toWorkspace: workspaceId,
                focus: true,
                focusWindow: true
              ) == true else {
            NSSound.beep()
            return
        }
    }
}
