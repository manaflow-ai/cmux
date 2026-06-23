import AppKit

extension GhosttyNSView {
    func appendCurrentSurfaceNotificationMuteMenuItems(to menu: NSMenu) {
        guard tabId != nil, terminalSurface?.id != nil else { return }

        let muteItem = NSMenuItem(
            title: String(localized: "terminalContextMenu.muteTabNotifications", defaultValue: "Mute Tab Notifications"),
            action: nil,
            keyEquivalent: ""
        )
        muteItem.image = NSImage(systemSymbolName: "bell.slash", accessibilityDescription: nil)
        let submenu = NSMenu()
        for duration in NotificationMuteDuration.allCases {
            let item = NSMenuItem(
                title: duration.title,
                action: #selector(muteCurrentSurfaceNotifications(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration.interval
            submenu.addItem(item)
        }
        muteItem.submenu = submenu

        if menu.items.last?.isSeparatorItem == false {
            menu.addItem(.separator())
        }
        menu.addItem(muteItem)

        if let surfaceId = terminalSurface?.id,
           TerminalNotificationStore.shared.activeSurfaceNotificationMuteExpiration(forSurfaceId: surfaceId) != nil {
            let unmuteItem = NSMenuItem(
                title: String(localized: "terminalContextMenu.unmuteTabNotifications", defaultValue: "Unmute Tab Notifications"),
                action: #selector(unmuteCurrentSurfaceNotifications(_:)),
                keyEquivalent: ""
            )
            unmuteItem.target = self
            unmuteItem.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
            menu.addItem(unmuteItem)
        }
    }

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

    @objc func muteCurrentSurfaceNotifications(_ sender: Any?) {
        guard let tabId,
              let surfaceId = terminalSurface?.id,
              let item = sender as? NSMenuItem,
              let interval = item.representedObject as? TimeInterval,
              interval.isFinite,
              interval > 0 else {
            NSSound.beep()
            return
        }
        TerminalNotificationStore.shared.muteNotifications(
            forTabId: tabId,
            surfaceId: surfaceId,
            until: Date().addingTimeInterval(interval)
        )
    }

    @objc func unmuteCurrentSurfaceNotifications(_ sender: Any?) {
        guard let surfaceId = terminalSurface?.id else {
            NSSound.beep()
            return
        }
        TerminalNotificationStore.shared.unmuteNotifications(forSurfaceId: surfaceId)
    }
}
