import CmuxNextDaemon
import CmuxNextOnboarding
import Foundation

extension AppOnboardingServices {
    var canImportClassicSessions: Bool {
        FileManager.default.fileExists(atPath: ClassicSessionImporter().fileURL.path)
    }

    func scanClassicSessions() async -> [ClassicSessionWorkspace] {
        await Task.detached { (try? ClassicSessionImporter().read()) ?? [] }.value
    }

    /// Recreates local workspace shells and terminal tabs. Classic commands,
    /// scrollback, and remote panels are intentionally ignored.
    func importClassicSessions(_ workspaces: [ClassicSessionWorkspace]) {
        guard let windows = services.windows else { return }
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            for saved in workspaces {
                do {
                    let id = try await windows.createWorkspace(WorkspaceSpawn(cwd: saved.workingDirectory, name: saved.name), into: target)
                    guard let daemon = services.machines.daemon(forWorkspace: id), let connection = daemon.connection else { continue }
                    try await restoreClassicLayout(saved.layout, workspaceID: id, connection: connection)
                }
                catch { services.daemon.logger.error("classic session import failed: \(String(describing: error), privacy: .public)") }
            }
        }
    }

    /// Rebuilds the imported topology through the same daemon builder used by
    /// workspace duplication. It preserves pane splits, tab order and working
    /// directories without replaying any saved command or scrollback.
    private func restoreClassicLayout(_ layout: ClassicSessionLayout, workspaceID: String, connection: DaemonConnection) async throws {
        let blueprint = WorkspaceBlueprint(
            name: workspaceID,
            color: nil,
            icon: nil,
            screens: [WorkspaceBlueprint.Screen(name: nil, columns: [
                WorkspaceBlueprint.Column(width: nil, root: blueprintNode(layout))
            ])]
        )
        try await WorkspaceBlueprintBuilder(
            connection: connection,
            key: WorkspaceKey(rawValue: workspaceID),
            browsers: false,
            defaultEngine: .webkit
        ).build(blueprint)
        try await restoreClassicTitles(layout, workspaceID: workspaceID, connection: connection)
    }

    private func blueprintNode(_ layout: ClassicSessionLayout) -> WorkspaceBlueprint.Node {
        switch layout {
        case .pane(let pane):
            return .pane(pane.tabs.map { .terminal(cwd: $0.workingDirectory) })
        case .split(let orientation, let ratio, let first, let second):
            return .split(
                direction: orientation == .horizontal ? .right : .down,
                ratio: ratio,
                a: blueprintNode(first),
                b: blueprintNode(second)
            )
        }
    }

    private func classicTabs(_ layout: ClassicSessionLayout) -> [ClassicSessionTab] {
        switch layout {
        case .pane(let pane): pane.tabs
        case .split(_, _, let first, let second): classicTabs(first) + classicTabs(second)
        }
    }

    private func restoreClassicTitles(_ layout: ClassicSessionLayout, workspaceID: String, connection: DaemonConnection) async throws {
        let tree = try await connection.listWorkspaces()
        guard let workspace = tree.workspaces.first(where: { $0.id.rawValue == workspaceID }),
              let screen = workspace.screens.first else { return }
        let surfaces = screen.layout.paneIDs.flatMap { paneID in
            screen.panes.first(where: { $0.handle == paneID })?.tabs.map(\.surface) ?? []
        }
        for (surface, tab) in zip(surfaces, classicTabs(layout)) {
            if let title = tab.title, !title.isEmpty { try await connection.renameTab(surface, to: title) }
        }
    }
}
