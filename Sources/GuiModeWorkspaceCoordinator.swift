import Foundation

/// Owns GUI Mode workspace creation so every entry point has identical focus and layout semantics.
@MainActor
final class GuiModeWorkspaceCoordinator {
    static let commandPaletteCommandId = "palette.newGuiMode"

    @discardableResult
    func createHomeWorkspace(in tabManager: TabManager) -> Workspace? {
        guard let workspace = tabManager.addWorkspaceIfActive(
            title: String(localized: "guiMode.workspace.home.title", defaultValue: "GUI Mode"),
            select: true,
            autoRefreshMetadata: false
        ) else { return nil }
        guard installGuiPanel(in: workspace, state: .home) != nil else {
            tabManager.closeWorkspace(workspace, recordHistory: false)
            return nil
        }
        return workspace
    }

    @discardableResult
    func createTaskWorkspace(
        prompt: String,
        providerID: GuiModeProviderID,
        sourcePanelId: UUID,
        preferredWorkspaceId: UUID,
        isRequestCurrent: @MainActor @escaping () -> Bool = { true }
    ) throws -> Workspace {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw AgentSessionBridgeError.missingParameter("prompt") }
        guard isRequestCurrent() else { throw AgentSessionBridgeError.invalidRequest }
        guard let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(panelId: sourcePanelId, preferredWorkspaceId: preferredWorkspaceId) else {
            throw AgentSessionBridgeError.invalidRequest
        }
        guard let workspace = location.tabManager.addWorkspaceIfActive(
            title: Self.taskWorkspaceTitle(prompt: trimmedPrompt),
            workingDirectory: location.workspace.currentDirectory,
            select: true,
            autoRefreshMetadata: false
        ) else { throw AgentSessionBridgeError.invalidRequest }
        do {
            guard isRequestCurrent() else { throw AgentSessionBridgeError.invalidRequest }
            guard let guiPanel = installGuiPanel(
                in: workspace,
                state: .taskWorktreePR(prompt: trimmedPrompt, providerID: providerID)
            ),
            let pane = workspace.paneId(forPanelId: guiPanel.id) else {
                throw AgentSessionBridgeError.invalidRequest
            }
            guard isRequestCurrent() else { throw AgentSessionBridgeError.invalidRequest }
            guard workspace.splitPaneWithNewTerminal(
                targetPane: pane,
                orientation: .horizontal,
                insertFirst: false,
                workingDirectory: location.workspace.currentDirectory,
                initialInput: Self.taskWorktreePRInput(prompt: trimmedPrompt, providerID: providerID),
                initialCommand: providerID.launchCommand
            ) != nil else {
                throw AgentSessionBridgeError.invalidRequest
            }
            guard isRequestCurrent() else { throw AgentSessionBridgeError.invalidRequest }
            return workspace
        } catch {
            location.tabManager.closeWorkspace(workspace, recordHistory: false)
            throw error
        }
    }

    @discardableResult
    private func installGuiPanel(in workspace: Workspace, state: GuiModePanelState) -> AgentSessionPanel? {
        let previousPanelId = workspace.focusedPanelId
        guard let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              let panel = workspace.newAgentSessionSurface(
                  inPane: pane,
                  rendererKind: .guiMode,
                  workingDirectory: workspace.currentDirectory,
                  focus: true,
                  guiModeState: state
              ) else { return nil }
        if let previousPanelId, previousPanelId != panel.id {
            _ = workspace.closePanel(previousPanelId, force: true)
        }
        return panel
    }

    static func taskWorktreePRCommand(prompt: String, providerID: GuiModeProviderID) -> String {
        "/task-worktree-pr --provider \(providerID.rawValue) \(Self.shellQuoted(prompt))"
    }

    static func taskWorktreePRInput(prompt: String, providerID: GuiModeProviderID) -> String {
        Self.taskWorktreePRCommand(prompt: prompt, providerID: providerID) + "\n"
    }

    static func taskWorkspaceTitle(prompt: String) -> String {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !normalized.isEmpty else {
            return String(localized: "guiMode.workspace.task.title", defaultValue: "GUI Task")
        }
        return String.localizedStringWithFormat(
            String(localized: "guiMode.workspace.task.format", defaultValue: "GUI: %@"),
            String(normalized.prefix(48))
        )
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
