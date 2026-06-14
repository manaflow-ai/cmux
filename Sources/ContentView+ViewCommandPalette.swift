import Foundation

extension ContentView {
    static func commandPaletteViewCommandContributions() -> [CommandPaletteCommandContribution] {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        return [
            CommandPaletteCommandContribution(
                commandId: "palette.triggerFlash",
                title: constant(String(localized: "command.triggerFlash.title", defaultValue: "Flash Focused Panel")),
                subtitle: constant(String(localized: "command.triggerFlash.subtitle", defaultValue: "View")),
                keywords: ["flash", "highlight", "focus", "panel"]
            ),
            CommandPaletteCommandContribution(
                commandId: "palette.openTaskManager",
                title: constant(String(localized: "taskManager.title", defaultValue: "Task Manager")),
                subtitle: constant(String(localized: "command.closeWindow.subtitle", defaultValue: "Window")),
                keywords: ["task", "manager", "process", "cpu", "memory", "kill"]
            ),
            CommandPaletteCommandContribution(
                commandId: GuiModeWorkspaceCoordinator.commandPaletteCommandId,
                title: constant(String(localized: "guiMode.command.enable.title", defaultValue: "Enable GUI Mode")),
                subtitle: constant(String(localized: "guiMode.command.enable.subtitle", defaultValue: "Workspace")),
                keywords: ["gui", "mode", "homepage", "task", "worktree", "pr"]
            ),
        ]
    }

    func registerViewCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.triggerFlash") {
            tabManager.triggerFocusFlash()
        }
        registry.register(commandId: "palette.openTaskManager") {
            TaskManagerWindowController.shared.show()
        }
        registry.register(commandId: GuiModeWorkspaceCoordinator.commandPaletteCommandId) {
            GuiModeWorkspaceCoordinator.createHomeWorkspace(in: tabManager)
        }
    }
}

enum GuiModeWorkspaceCoordinator {
    static let commandPaletteCommandId = "palette.enableGuiMode"

    @discardableResult
    @MainActor
    static func createHomeWorkspace(in tabManager: TabManager) -> Workspace {
        tabManager.addWorkspace(
            title: String(localized: "guiMode.workspace.home.title", defaultValue: "GUI Mode"),
            initialSurface: .guiMode,
            select: true,
            autoRefreshMetadata: false
        )
    }

    @discardableResult
    @MainActor
    static func createTaskWorkspace(
        prompt: String,
        providerID: GuiModeProviderID,
        sourcePanelId: UUID,
        preferredWorkspaceId: UUID
    ) throws -> Workspace {
        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                panelId: sourcePanelId,
                preferredWorkspaceId: preferredWorkspaceId
              ) else {
            throw AgentSessionBridgeError.invalidRequest
        }

        let title = taskWorkspaceTitle(prompt: prompt)
        let workspace = location.tabManager.addWorkspace(
            title: title,
            workingDirectory: location.workspace.currentDirectory,
            initialSurface: .guiMode,
            inheritWorkingDirectory: false,
            select: true,
            autoRefreshMetadata: false
        )

        guard let guiPanel = workspace.panels.values.compactMap({ $0 as? AgentSessionPanel }).first(where: {
            $0.rendererKind == .guiMode
        }) else {
            throw AgentSessionBridgeError.invalidRequest
        }
        guiPanel.configureGuiModeTask(prompt: prompt, providerID: providerID)

        guard let guiPaneId = workspace.paneId(forPanelId: guiPanel.id) else {
            throw AgentSessionBridgeError.invalidRequest
        }
        let initialInput = taskWorktreePRCommand(prompt: prompt, providerID: providerID)
        _ = workspace.splitPaneWithNewTerminal(
            targetPane: guiPaneId,
            orientation: .horizontal,
            insertFirst: false,
            workingDirectory: location.workspace.currentDirectory,
            initialInput: initialInput
        )
        return workspace
    }

    static func taskWorktreePRCommand(prompt: String, providerID: GuiModeProviderID) -> String {
        "/task-worktree-pr --provider \(providerID.rawValue) \(shellQuoted(prompt))"
    }

    static func taskWorkspaceTitle(prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = String(trimmed.prefix(48))
        guard !summary.isEmpty else {
            return String(localized: "guiMode.workspace.task.title", defaultValue: "GUI Task")
        }
        return String(
            format: String(localized: "guiMode.workspace.task.format", defaultValue: "GUI: %@"),
            summary
        )
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
