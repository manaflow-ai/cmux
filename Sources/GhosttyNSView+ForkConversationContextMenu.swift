import AppKit

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
        let nativeAvailability = currentAgentConversationForkAvailability()
        let transferTargets = availableForkTargets()
        guard nativeAvailability.isAvailable
            || nativeAvailability == .agentIndexRefreshing
            || !transferTargets.isEmpty else {
            return false
        }

        if nativeAvailability == .agentIndexRefreshing, transferTargets.isEmpty {
            let item = menu.addItem(
                withTitle: String(localized: "terminalContextMenu.forkConversation", defaultValue: "Fork Conversation"),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            item.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            return true
        }

        if nativeAvailability.isAvailable {
            let defaultDestination = AgentConversationForkDefaultSettings.current()
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
            submenuItem.submenu = makeForkDestinationSubmenu(selectedDestination: defaultDestination) {
                $0.rawValue
            }
            menu.addItem(submenuItem)
        }

        if !transferTargets.isEmpty {
            let harnessItem = NSMenuItem(
                title: String(
                    localized: "terminalContextMenu.forkConversationWith",
                    defaultValue: "Fork Conversation with"
                ),
                action: nil,
                keyEquivalent: ""
            )
            harnessItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
            let harnessMenu = NSMenu()
            for target in transferTargets {
                let targetItem = NSMenuItem(title: target.title, action: nil, keyEquivalent: "")
                targetItem.submenu = makeForkDestinationSubmenu { destination in
                    AgentConversationForkRequest(
                        target: target,
                        destination: destination
                    )
                }
                harnessMenu.addItem(targetItem)
            }
            harnessItem.submenu = harnessMenu
            menu.addItem(harnessItem)
        }

        return true
    }

    private func makeForkDestinationSubmenu(
        selectedDestination: AgentConversationForkDestination? = nil,
        representedObject: (AgentConversationForkDestination) -> Any
    ) -> NSMenu {
        let menu = NSMenu()
        for destination in AgentConversationForkDestination.allCases {
            let item = NSMenuItem(
                title: destination.settingsTitle,
                action: #selector(forkCurrentAgentConversation(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = representedObject(destination)
            item.state = destination == selectedDestination ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func availableForkTargets() -> [AgentConversationForkTarget] {
        guard let panelId = terminalSurface?.id,
              let workspace = AppDelegate.shared?.workspaceContainingPanel(panelId: panelId)?.workspace else {
            return []
        }
        return workspace.actionableAgentConversationForkTargets(forPanelId: panelId)
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
        let availability = located.workspace.forkAgentConversationContextMenuPresentationAvailability(
            forPanelId: panelId
        )
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

        let request: AgentConversationForkRequest
        if let item = sender as? NSMenuItem,
           let representedRequest = item.representedObject as? AgentConversationForkRequest {
            request = representedRequest
        } else if let item = sender as? NSMenuItem,
           let rawDestination = item.representedObject as? String,
           let representedDestination = AgentConversationForkDestination(rawValue: rawDestination) {
            request = .sameHarness(destination: representedDestination)
        } else {
            request = .sameHarness(
                destination: AgentConversationForkDefaultSettings.current()
            )
        }

        Task { @MainActor in
            guard await workspace.forkAgentConversationFromContextMenu(
                fromPanelId: panelId,
                request: request
            ) else {
                NSSound.beep()
                return
            }
        }
    }
}
