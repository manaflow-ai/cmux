import CmuxFleet
import Darwin
import Foundation

/// Performs Fleet's app-side workspace, terminal, process, and notification effects.
@MainActor
final class FleetAppActuator: FleetActuating {
    /// Creates or reuses the task worktree and attaches it to an unfocused workspace.
    func provisionWorkspace(task: FleetTask, fleet: FleetConfig) async -> Result<FleetProvisionOutcome, FleetActuationError> {
        let safeName = FleetPathSanitizer().directoryName(for: task.id.rawValue)
        let directory = URL(fileURLWithPath: fleet.workspaceRoot).appendingPathComponent(safeName, isDirectory: true).path
        let branch = "fleet/\(safeName)"
        let filesystemResult = await Self.prepareDirectory(
            repoRoot: fleet.repoRoot,
            workspaceRoot: fleet.workspaceRoot,
            directory: directory,
            branch: branch
        )
        guard case .success(let isBrandNew) = filesystemResult else {
            if case .failure(let error) = filesystemResult {
                return .failure(error)
            }
            return .failure(FleetActuationError(message: "Failed to provision workspace"))
        }

        guard let tabManager = Self.targetTabManager() else {
            return .failure(FleetActuationError(message: "TabManager not available"))
        }
        let groupID: UUID
        if let existing = tabManager.workspaceGroups.first(where: { $0.name == fleet.name })?.id {
            groupID = existing
        } else if let created = tabManager.createWorkspaceGroup(
            name: fleet.name,
            childWorkspaceIds: [],
            anchorWorkingDirectory: fleet.repoRoot,
            selectAnchor: false,
            collapseSidebarSelection: true
        ) {
            groupID = created
        } else {
            return .failure(FleetActuationError(message: "Failed to create workspace group"))
        }

        let workspace = tabManager.addWorkspace(
            title: task.title,
            workingDirectory: directory,
            initialTerminalCommand: nil,
            initialTerminalInput: nil,
            select: false,
            eagerLoadTerminal: true,
            autoWelcomeIfNeeded: false,
            autoRefreshMetadata: true
        )
        tabManager.addWorkspaceToGroup(
            workspaceId: workspace.id,
            groupId: groupID,
            placement: .top,
            referenceWorkspaceId: nil
        )

        guard let surfaceID = workspace.focusedTerminalPanel?.id ?? workspace.focusedPanelId else {
            return .failure(FleetActuationError(message: "Workspace has no terminal surface"))
        }
        return .success(FleetProvisionOutcome(
            workspaceID: workspace.id.uuidString,
            surfaceID: surfaceID.uuidString,
            directoryPath: directory,
            branch: branch,
            isBrandNew: isBrandNew
        ))
    }

    /// Sends text to the task terminal surface.
    func sendAgentCommand(workspaceID: String, surfaceID: String, text: String) -> Bool {
        guard let target = Self.terminalPanel(workspaceID: workspaceID, surfaceID: surfaceID) else {
            return false
        }
        switch target.terminalPanel.sendInputResult(text) {
        case .sent, .queued:
            return true
        case .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }

    /// Terminates the task agent by PID when known, otherwise sends Ctrl-C.
    func killAgent(workspaceID: String, surfaceID: String, pid: Int32?) {
        if let pid {
            _ = kill(pid, SIGTERM)
        } else {
            _ = sendAgentCommand(workspaceID: workspaceID, surfaceID: surfaceID, text: "\u{03}")
        }
    }

    /// Closes the task workspace when the app can do so without removing the last workspace.
    func closeWorkspace(workspaceID: String) {
        guard let workspaceID = UUID(uuidString: workspaceID),
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              tabManager.tabs.count > 1
        else { return }
        tabManager.closeWorkspace(workspace)
    }

    /// Posts the user-visible Fleet notification for a task state transition.
    func postNotification(fleet: FleetConfig, task: FleetTask, kind: FleetNotificationKind) {
        guard let workspaceID = task.workspaceID,
              let surfaceID = task.surfaceID,
              let workspaceUUID = UUID(uuidString: workspaceID),
              let surfaceUUID = UUID(uuidString: surfaceID)
        else { return }
        TerminalController.shared.deliverNotificationSynchronously(
            tabId: workspaceUUID,
            surfaceId: surfaceUUID,
            title: notificationTitle(kind: kind),
            subtitle: fleet.name,
            body: notificationBody(task: task, kind: kind)
        )
    }

    private static func targetTabManager() -> TabManager? {
        AppDelegate.shared?.activeTabManagerForCommands()
            ?? AppDelegate.shared?.currentScriptableMainWindow()?.tabManager
    }

    private static func terminalPanel(
        workspaceID: String,
        surfaceID: String
    ) -> (workspace: Workspace, terminalPanel: TerminalPanel)? {
        guard let workspaceUUID = UUID(uuidString: workspaceID),
              let surfaceUUID = UUID(uuidString: surfaceID),
              let tabManager = AppDelegate.shared?.tabManagerFor(tabId: workspaceUUID),
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceUUID }),
              let terminalPanel = workspace.terminalPanel(for: surfaceUUID)
        else { return nil }
        return (workspace, terminalPanel)
    }

    private static func prepareDirectory(
        repoRoot: String,
        workspaceRoot: String,
        directory: String,
        branch: String
    ) async -> Result<Bool, FleetActuationError> {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(atPath: workspaceRoot, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: directory),
                   fileManager.fileExists(atPath: "\(directory)/.git") {
                    return .success(false)
                }
                if fileManager.fileExists(atPath: "\(repoRoot)/.git") {
                    let first = Self.runGit(["-C", repoRoot, "worktree", "add", directory, "-b", branch])
                    if first.succeeded {
                        return .success(true)
                    }
                    let second = Self.runGit(["-C", repoRoot, "worktree", "add", directory, branch])
                    if second.succeeded {
                        return .success(false)
                    }
                    return .failure(FleetActuationError(message: second.output.isEmpty ? first.output : second.output))
                }
                try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
                return .success(true)
            } catch {
                return .failure(FleetActuationError(message: error.localizedDescription))
            }
        }.value
    }

    /// Runs git from a detached provisioning task; this must not hop back to the main actor.
    private nonisolated static func runGit(_ arguments: [String]) -> (succeeded: Bool, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func notificationTitle(kind: FleetNotificationKind) -> String {
        switch kind {
        case .needsInput:
            String(localized: "fleet.notification.needsInput.title", defaultValue: "Fleet task needs input")
        case .retryScheduled:
            String(localized: "fleet.notification.retryScheduled.title", defaultValue: "Fleet task retrying")
        case .awaitingReview:
            String(localized: "fleet.notification.awaitingReview.title", defaultValue: "Fleet task ready for review")
        case .failed:
            String(localized: "fleet.notification.failed.title", defaultValue: "Fleet task failed")
        case .cancelled:
            String(localized: "fleet.notification.cancelled.title", defaultValue: "Fleet task cancelled")
        }
    }

    private func notificationBody(task: FleetTask, kind: FleetNotificationKind) -> String {
        switch kind {
        case .needsInput:
            String(localized: "fleet.notification.needsInput.body", defaultValue: "\(task.title) is waiting for your response.")
        case .retryScheduled:
            String(localized: "fleet.notification.retryScheduled.body", defaultValue: "\(task.title) will retry after backoff.")
        case .awaitingReview:
            String(localized: "fleet.notification.awaitingReview.body", defaultValue: "\(task.title) opened a pull request.")
        case .failed:
            String(localized: "fleet.notification.failed.body", defaultValue: "\(task.title) exhausted its retry attempts.")
        case .cancelled:
            String(localized: "fleet.notification.cancelled.body", defaultValue: "\(task.title) was cancelled.")
        }
    }
}
