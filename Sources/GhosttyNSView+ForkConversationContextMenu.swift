import AppKit
import CMUXAgentLaunch

extension GhosttyNSView {
    func appendCurrentSurfaceContextMenuItems(to menu: NSMenu) {
        if appendForkCurrentAgentConversationMenuItems(to: menu) {
            menu.addItem(.separator())
        }
        appendMoveCurrentSurfaceMoveMenuItems(to: menu)
        menu.addItem(.separator())
    }

    @discardableResult
    func appendForkCurrentAgentConversationMenuItems(to menu: NSMenu) -> Bool {
        let availability = currentAgentConversationForkAvailability()
        guard availability.isAvailable || availability == .agentIndexRefreshing else { return false }

        if availability == .agentIndexRefreshing {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.forkConversation", defaultValue: "Fork Conversation"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            return true
        }

        let defaultDestination = AgentConversationForkDestination.configuredDefault()
        let primaryItem = menu.addItem(
            withTitle: String(localized: "terminalContextMenu.forkConversation", defaultValue: "Fork Conversation"),
            action: #selector(forkCurrentAgentConversation(_:)),
            keyEquivalent: ""
        )
        primaryItem.target = self
        primaryItem.representedObject = defaultDestination.rawValue
        primaryItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)

        let submenuItem = NSMenuItem(
            title: String(localized: "terminalContextMenu.forkConversationTo", defaultValue: "Fork Conversation To"),
            action: nil,
            keyEquivalent: ""
        )
        submenuItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let submenu = NSMenu()
        for destination in AgentConversationForkDestination.allCases {
            let item = NSMenuItem(
                title: destination.settingsTitle,
                action: #selector(forkCurrentAgentConversation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = destination.rawValue
            item.state = destination == defaultDestination ? .on : .off
            submenu.addItem(item)
        }
        submenuItem.submenu = submenu
        menu.addItem(submenuItem)

        return true
    }

    private func currentAgentConversationForkAvailability() -> WorkspaceForkAgentConversationAvailability {
        guard let panelId = terminalSurface?.id else {
#if DEBUG
            cmuxDebugLog("fork.contextMenu.hidden reason=missing_terminal_surface")
#endif
            return .noAgentSnapshot
        }
        guard let located = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId) else {
#if DEBUG
            cmuxDebugLog(
                "fork.contextMenu.hidden panel=\(panelId.uuidString.prefix(5)) " +
                "reason=missing_workspace"
            )
#endif
            return .noAgentSnapshot
        }
        let availability = located.workspace.forkAgentConversationContextMenuOpenAvailability(
            forPanelId: panelId
        )
        if availability == .agentIndexRefreshing,
           !located.workspace.forkAgentConversationContextMenuAvailability(forPanelId: panelId).isAvailable {
            return .noAgentSnapshot
        }
#if DEBUG
        if !availability.isAvailable {
            cmuxDebugLog(
                "fork.contextMenu.hidden workspace=\(located.workspace.id.uuidString.prefix(5)) " +
                "panel=\(panelId.uuidString.prefix(5)) reason=\(availability.diagnosticReason)"
            )
        }
#endif
        return availability
    }

    @objc func forkCurrentAgentConversation(_ sender: Any?) {
        guard let panelId = terminalSurface?.id,
              let located = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId) else {
            NSSound.beep()
            return
        }
        let workspace = located.workspace

        let destination: AgentConversationForkDestination
        if let item = sender as? NSMenuItem,
           let rawDestination = item.representedObject as? String,
           let representedDestination = AgentConversationForkDestination(rawValue: rawDestination) {
            destination = representedDestination
        } else {
            destination = AgentConversationForkDestination.configuredDefault()
        }

        guard workspace.forkAgentConversationFromContextMenu(
            fromPanelId: panelId,
            destination: destination
        ) else {
            NSSound.beep()
            return
        }
    }
}
