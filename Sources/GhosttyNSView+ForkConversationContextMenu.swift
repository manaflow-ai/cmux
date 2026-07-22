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

        menu.addItem(
            forkConversationHarnessFirstMenuItem(defaultDestination: defaultDestination)
        )
        menu.addItem(
            forkConversationDestinationFirstMenuItem(defaultDestination: defaultDestination)
        )

        return true
    }

    private func forkConversationHarnessFirstMenuItem(
        defaultDestination: AgentConversationForkDestination
    ) -> NSMenuItem {
        let rootItem = NSMenuItem(
            title: String(
                localized: "terminalContextMenu.forkConversationByHarness",
                defaultValue: "Fork by Harness"
            ),
            action: nil,
            keyEquivalent: ""
        )
        rootItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let rootMenu = NSMenu()
        for harness in AgentConversationForkRequest.TargetHarness.allCases {
            let harnessItem = NSMenuItem(title: harness.title, action: nil, keyEquivalent: "")
            let destinationMenu = NSMenu()
            for destination in AgentConversationForkDestination.allCases {
                destinationMenu.addItem(forkConversationLeafMenuItem(
                    request: AgentConversationForkRequest(
                        targetHarness: harness,
                        destination: destination
                    ),
                    defaultDestination: defaultDestination,
                    title: destination.settingsTitle
                ))
            }
            harnessItem.submenu = destinationMenu
            rootMenu.addItem(harnessItem)
        }
        rootItem.submenu = rootMenu
        return rootItem
    }

    private func forkConversationDestinationFirstMenuItem(
        defaultDestination: AgentConversationForkDestination
    ) -> NSMenuItem {
        let rootItem = NSMenuItem(
            title: String(
                localized: "terminalContextMenu.forkConversationByDestination",
                defaultValue: "Fork by Destination"
            ),
            action: nil,
            keyEquivalent: ""
        )
        rootItem.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)
        let rootMenu = NSMenu()
        for destination in AgentConversationForkDestination.allCases {
            let destinationItem = NSMenuItem(title: destination.settingsTitle, action: nil, keyEquivalent: "")
            let harnessMenu = NSMenu()
            for harness in AgentConversationForkRequest.TargetHarness.allCases {
                harnessMenu.addItem(forkConversationLeafMenuItem(
                    request: AgentConversationForkRequest(
                        targetHarness: harness,
                        destination: destination
                    ),
                    defaultDestination: defaultDestination,
                    title: harness.title
                ))
            }
            destinationItem.submenu = harnessMenu
            rootMenu.addItem(destinationItem)
        }
        rootItem.submenu = rootMenu
        return rootItem
    }

    private func forkConversationLeafMenuItem(
        request: AgentConversationForkRequest,
        defaultDestination: AgentConversationForkDestination,
        title: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title,
            action: #selector(forkCurrentAgentConversation(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = request
        item.state = request.targetHarness == .current && request.destination == defaultDestination
            ? .on
            : .off
        return item
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
        if let representedRequest = (sender as? NSMenuItem)?.representedObject as? AgentConversationForkRequest {
            request = representedRequest
        } else if let rawDestination = (sender as? NSMenuItem)?.representedObject as? String,
                  let representedDestination = AgentConversationForkDestination(rawValue: rawDestination) {
            request = AgentConversationForkRequest(
                targetHarness: .current,
                destination: representedDestination
            )
        } else {
            request = AgentConversationForkRequest(
                targetHarness: .current,
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
