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
        let title = String(
            localized: "settings.terminal.resumeCommands",
            defaultValue: "Resume Commands"
        )

        switch currentSurfaceResumeContextMenuState() {
        case .unavailable, .agentManaged:
            return false
        case .approvalPending:
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return true
        case .unbound:
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let setItem = submenu.addItem(
                withTitle: String(
                    localized: "settings.automation.socketPassword.set",
                    defaultValue: "Set"
                ),
                action: #selector(makeCurrentSurfaceRestorable(_:)),
                keyEquivalent: ""
            )
            setItem.target = self
            item.submenu = submenu
            menu.addItem(item)
            return true
        case .ordinary(let command):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let summary = currentSurfaceResumeCommandSummary(command)
            let statusItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            statusItem.toolTip = command
            submenu.addItem(statusItem)
            submenu.addItem(.separator())

            let editItem = submenu.addItem(
                withTitle: String(
                    localized: "settings.common.edit",
                    defaultValue: "Edit"
                ),
                action: #selector(editCurrentSurfaceResumeCommand(_:)),
                keyEquivalent: ""
            )
            editItem.target = self

            let clearItem = submenu.addItem(
                withTitle: String(
                    localized: "settings.automation.socketPassword.clear",
                    defaultValue: "Clear"
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
        let routing = currentSurfaceResumeRouting(surfaceID: surfaceID)
        if let managedBinding = TerminalController.shared.controlSurfaceManagedAgentResumeBinding(
            routing: routing,
            explicitTargetID: surfaceID,
            hasResolvedWindowID: false
        ), managedBinding.isAgentHookBinding {
            return .agentManaged
        }
        let resolution = TerminalController.shared.controlSurfaceResumeGet(
            routing: routing,
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
                // A user-edited command never inherits process-detected or agent trust.
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
        guard case .result = clearCurrentSurfaceResumeBindingFromContextMenu() else {
            NSSound.beep()
            return
        }
    }

    private func presentCurrentSurfaceResumeCommandEditor(existingCommand: String?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            localized: "settings.terminal.resumeCommands",
            defaultValue: "Resume Commands"
        )
        alert.informativeText = String(
            localized: "settings.terminal.resumeCommands.subtitle",
            defaultValue: "Review signed command prefixes that can restore non-agent terminal surfaces."
        )

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = existingCommand ?? ""
        // Only a saved resume binding is authoritative enough to prefill. A terminal's
        // initial launch command can also be cmux transport or placeholder plumbing.
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        alert.window.initialFirstResponder = field

        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                NSSound.beep()
                continue
            }

            let resolution = setCurrentSurfaceResumeBindingFromContextMenu(command: field.stringValue)
            if case .approvalPending(let message) = resolution {
                presentCurrentSurfaceResumeApprovalPending(message)
            } else if case .result = resolution {
                return
            } else {
                NSSound.beep()
            }
            return
        }
    }

    private func presentCurrentSurfaceResumeApprovalPending(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "settings.terminal.resumeCommands",
            defaultValue: "Resume Commands"
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
