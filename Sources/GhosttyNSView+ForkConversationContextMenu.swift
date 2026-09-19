import AppKit
import CmuxControlSocket
import Foundation

enum SurfaceResumeContextMenuState: Equatable {
    case unavailable
    case unbound
    case agentManaged
    case ordinary(command: String)
    case approvalPending
}

extension GhosttyNSView {
    func appendCurrentSurfaceContextMenuItems(to menu: NSMenu) {
        if appendCurrentSurfaceResumeMenuItems(to: menu) {
            menu.addItem(.separator())
        }
        if appendForkCurrentAgentConversationMenuItems(to: menu) {
            menu.addItem(.separator())
        }
        appendMoveCurrentSurfaceMoveMenuItems(to: menu)
        menu.addItem(.separator())
    }

    @discardableResult
    func appendCurrentSurfaceResumeMenuItems(to menu: NSMenu) -> Bool {
        switch currentSurfaceResumeContextMenuState() {
        case .unavailable:
            return false
        case .unbound:
            let item = menu.addItem(
                withTitle: String(
                    localized: "terminalContextMenu.makeRestorable",
                    defaultValue: "Make Restorable…"
                ),
                action: #selector(makeCurrentSurfaceRestorable(_:)),
                keyEquivalent: ""
            )
            item.target = self
            return true
        case .agentManaged:
            let item = menu.addItem(
                withTitle: String(
                    localized: "terminalContextMenu.agentResumeManaged",
                    defaultValue: "Agent Session Resume: Managed"
                ),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            return true
        case .approvalPending:
            let item = menu.addItem(
                withTitle: String(
                    localized: "terminalContextMenu.resumeCommandLoading",
                    defaultValue: "Resume Command: Loading…"
                ),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            return true
        case .ordinary(let command):
            let item = NSMenuItem(
                title: String(
                    localized: "terminalContextMenu.restorableTerminal",
                    defaultValue: "Restorable Terminal"
                ),
                action: nil,
                keyEquivalent: ""
            )
            let submenu = NSMenu()
            let summary = currentSurfaceResumeCommandSummary(command)
            let statusItem = NSMenuItem(
                title: String(
                    format: String(
                        localized: "terminalContextMenu.resumeCommandStatus",
                        defaultValue: "Resume Command: %@"
                    ),
                    summary
                ),
                action: nil,
                keyEquivalent: ""
            )
            statusItem.isEnabled = false
            statusItem.toolTip = command
            submenu.addItem(statusItem)
            submenu.addItem(.separator())

            let setItem = submenu.addItem(
                withTitle: String(
                    localized: "terminalContextMenu.setResumeCommand",
                    defaultValue: "Set Resume Command…"
                ),
                action: #selector(editCurrentSurfaceResumeCommand(_:)),
                keyEquivalent: ""
            )
            setItem.target = self

            let clearItem = submenu.addItem(
                withTitle: String(
                    localized: "terminalContextMenu.clearResumeCommand",
                    defaultValue: "Clear Resume Command"
                ),
                action: #selector(clearCurrentSurfaceResumeCommand(_:)),
                keyEquivalent: ""
            )
            clearItem.target = self

            item.submenu = submenu
            menu.addItem(item)
            return true
        }
    }

    func currentSurfaceResumeContextMenuState() -> SurfaceResumeContextMenuState {
        guard let surfaceID = terminalSurface?.id else { return .unavailable }
        let resolution = TerminalController.shared.controlSurfaceResumeGet(
            routing: currentSurfaceResumeRouting(surfaceID: surfaceID),
            explicitTargetID: surfaceID,
            hasResolvedWindowID: false,
            claimCheckpointID: nil,
            claimSource: nil,
            claimUpdatedAt: nil
        )
        switch resolution {
        case .result(let snapshot):
            guard let binding = snapshot.binding else { return .unbound }
            if binding.source == "agent-hook" {
                return .agentManaged
            }
            return .ordinary(command: binding.command)
        case .approvalPending:
            return .approvalPending
        default:
            return .unavailable
        }
    }

    @discardableResult
    func setCurrentSurfaceResumeBindingFromContextMenu(
        command: String
    ) -> ControlSurfaceResumeResolution {
        guard let surfaceID = terminalSurface?.id else { return .surfaceNotFound }
        switch currentSurfaceResumeContextMenuState() {
        case .agentManaged, .approvalPending:
            return .setFailed
        case .unavailable:
            return .surfaceNotFound
        case .unbound, .ordinary:
            break
        }

        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .emptyResumeCommand }

        return TerminalController.shared.controlSurfaceResumeSet(
            routing: currentSurfaceResumeRouting(surfaceID: surfaceID),
            explicitTargetID: surfaceID,
            hasResolvedWindowID: false,
            inputs: ControlSurfaceResumeSetInputs(
                name: nil,
                kind: nil,
                command: command,
                cwd: nil,
                checkpointID: nil,
                source: "manual",
                environment: nil,
                launchCommand: nil,
                permissionMode: nil,
                autoResume: false,
                remoteWorkspaceID: nil,
                remoteRelayParameters: nil
            )
        )
    }

    @discardableResult
    func clearCurrentSurfaceResumeBindingFromContextMenu() -> ControlSurfaceResumeResolution {
        guard let surfaceID = terminalSurface?.id else { return .surfaceNotFound }
        guard case .ordinary = currentSurfaceResumeContextMenuState() else {
            return .setFailed
        }
        return TerminalController.shared.controlSurfaceResumeClear(
            routing: currentSurfaceResumeRouting(surfaceID: surfaceID),
            explicitTargetID: surfaceID,
            hasResolvedWindowID: false,
            expectedCheckpointID: nil,
            expectedSource: nil,
            expectedUpdatedAt: nil,
            agentSessionEnded: false
        )
    }

    private func currentSurfaceResumeRouting(surfaceID: UUID) -> ControlRoutingSelectors {
        ControlRoutingSelectors(
            hasWindowIDParam: false,
            windowID: nil,
            groupID: nil,
            workspaceID: nil,
            surfaceID: surfaceID,
            paneID: nil
        )
    }

    private func currentSurfaceResumeCommandSummary(_ command: String) -> String {
        let singleLine = command
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard singleLine.count > 72 else { return singleLine }
        return String(singleLine.prefix(71)) + "…"
    }

    @objc func makeCurrentSurfaceRestorable(_ sender: Any?) {
        presentCurrentSurfaceResumeCommandEditor(existingCommand: nil)
    }

    @objc func editCurrentSurfaceResumeCommand(_ sender: Any?) {
        guard case .ordinary(let command) = currentSurfaceResumeContextMenuState() else {
            NSSound.beep()
            return
        }
        presentCurrentSurfaceResumeCommandEditor(existingCommand: command)
    }

    @objc func clearCurrentSurfaceResumeCommand(_ sender: Any?) {
        let resolution = clearCurrentSurfaceResumeBindingFromContextMenu()
        presentCurrentSurfaceResumeFailureIfNeeded(resolution)
    }

    private func presentCurrentSurfaceResumeCommandEditor(existingCommand: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = existingCommand == nil
            ? String(
                localized: "terminalContextMenu.makeRestorable.title",
                defaultValue: "Make Terminal Restorable"
            )
            : String(
                localized: "terminalContextMenu.setResumeCommand.title",
                defaultValue: "Set Resume Command"
            )
        alert.informativeText = String(
            localized: "terminalContextMenu.resumeCommand.message",
            defaultValue: "Enter a durable command cmux can use to restore this terminal after reopening the app. Automatic runs still follow Settings → Terminal → Resume Commands approvals."
        )

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = existingCommand ?? ""
        field.placeholderString = String(
            localized: "terminalContextMenu.resumeCommand.placeholder",
            defaultValue: "tmux attach -t work"
        )
        alert.accessoryView = field
        alert.addButton(
            withTitle: String(localized: "terminalContextMenu.resumeCommand.save", defaultValue: "Save")
        )
        alert.addButton(
            withTitle: String(localized: "terminalContextMenu.resumeCommand.cancel", defaultValue: "Cancel")
        )
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let resolution = setCurrentSurfaceResumeBindingFromContextMenu(command: field.stringValue)
        presentCurrentSurfaceResumeFailureIfNeeded(resolution)
    }

    private func presentCurrentSurfaceResumeFailureIfNeeded(
        _ resolution: ControlSurfaceResumeResolution
    ) {
        let message: String
        switch resolution {
        case .result:
            return
        case .approvalPending(let pendingMessage):
            message = pendingMessage
        case .emptyResumeCommand:
            message = String(
                localized: "terminalContextMenu.resumeCommand.empty",
                defaultValue: "Enter a resume command."
            )
        case .windowUnavailable, .surfaceNotFound:
            message = String(
                localized: "terminalContextMenu.resumeCommand.surfaceUnavailable",
                defaultValue: "This terminal is no longer available."
            )
        case .setFailed:
            message = String(
                localized: "terminalContextMenu.resumeCommand.updateFailed",
                defaultValue: "cmux could not update this terminal’s resume command."
            )
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "terminalContextMenu.resumeCommand.errorTitle",
            defaultValue: "Resume Command"
        )
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.runModal()
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

        let destination: AgentConversationForkDestination
        if let item = sender as? NSMenuItem,
           let rawDestination = item.representedObject as? String,
           let representedDestination = AgentConversationForkDestination(rawValue: rawDestination) {
            destination = representedDestination
        } else {
            destination = AgentConversationForkDefaultSettings.current()
        }

        Task { @MainActor in
            guard await workspace.forkAgentConversationFromContextMenu(
                fromPanelId: panelId,
                destination: destination
            ) else {
                NSSound.beep()
                return
            }
        }
    }
}
