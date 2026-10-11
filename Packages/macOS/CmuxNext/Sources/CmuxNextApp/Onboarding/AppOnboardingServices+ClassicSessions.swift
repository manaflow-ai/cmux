import CmuxNextDaemon
import CmuxNextOnboarding
import Foundation

/// Classic cmux session import (Leo, cx-aha.5), run by `workspace.importClassic`
/// (cx-rwlb): started by the person or an agent, never on launch.
extension AppOnboardingServices {

    /// Opens each workspace of classic's last saved session here and returns
    /// how many opened (0 when classic saved none). Recreates local workspace
    /// shells and terminal tabs; classic commands, scrollback, browser panels
    /// and SSH or Cloud VM workspaces are intentionally left out.
    func importClassicSessions() async throws -> Int {
        let importer = owner.classicSessions
        let workspaces = try await Task.detached { try (importer ?? ClassicSessionImporter()).read() }.value
        let windows = services.windows
        let target = windows.targetWindow(preferring: windows.active?.state.id)
        let machines = services.machines, logger = services.daemon.logger
        var opened = 0
        var lastError: (any Error)?
        // A workspace that held only browsers has no terminal to bring.
        for saved in workspaces where !classicTabs(saved.layout).isEmpty {
            do {
                // Recreated in their saved order: each one after the last loose row. An
                // explicit slot, because the daemon itself puts a new workspace at the
                // `workspaces.newPlacement` slot (top by default).
                var spawn = WorkspaceSpawn(cwd: saved.workingDirectory, name: saved.name)
                spawn.slot = .bottom(anchor: nil)
                let id = try await windows.createWorkspace(spawn, into: target)
                guard let daemon = machines.daemon(forWorkspace: id), let connection = daemon.connection else {
                    throw ClassicImportFailure.noDaemon
                }
                try await restoreClassicLayout(saved.layout, workspaceID: id, connection: connection)
                opened += 1
            } catch {
                lastError = error
                logger.error("classic session import failed: \(String(describing: error), privacy: .public)")
            }
        }
        // One workspace that did not open is logged; none opening is the action's failure.
        if opened == 0, let lastError { throw lastError }
        return opened
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
        guard let workspace = tree.workspaces.first(where: { $0.key?.rawValue == workspaceID }),
              let screen = workspace.screens.first else { return }
        let paneIDs = screen.layout.paneIDs
        let panes = screen.panes
        var surfaces: [SurfaceID] = []
        for paneID in paneIDs {
            guard let pane = panes.first(where: { $0.id == paneID }) else { continue }
            surfaces.append(contentsOf: pane.tabs.map(\.surface))
        }
        for (surface, tab) in zip(surfaces, classicTabs(layout)) {
            if let title = tab.title, !title.isEmpty { try await connection.renameTab(surface, to: title) }
        }
    }
}

private enum ClassicImportFailure: Error {
    /// The new workspace's daemon has no connection to build its panes on.
    case noDaemon
}
