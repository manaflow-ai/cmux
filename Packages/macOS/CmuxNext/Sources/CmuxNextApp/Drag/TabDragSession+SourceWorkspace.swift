import AppKit
import CmuxNextBridge
import CmuxNextDaemon

// The last tab of the last pane takes its workspace along (coordinator
// decision 2026-09-30, REWRITE.md round 3; Chrome: dragging a window's only
// tab moves the window). A drag that carries every tab of its workspace
// either moves the workspace itself (tear-off, sidebar gap), or, when the
// tabs land in another workspace, closes the emptied workspace instead of
// leaving it for the empty-workspace repair to refill. When that workspace
// was its window's last, the window closes in the same step
// (`WindowRegistry`).
extension TabDragSession {
    /// The source workspace a committed tab move leaves empty, if any.
    func emptiedSourceWorkspace(_ drag: Drag) -> WorkspaceModel? {
        guard drag.source.context.emptiesSourceWorkspace else { return nil }
        return services.workspace(id: drag.source.context.sourceWorkspaceID)
    }

    func claimClosing(_ workspace: WorkspaceModel) {
        guard let key = workspace.key else { return }
        repair(for: workspace).beginClosing(key)
    }

    /// After the move settled: closes the source workspace when it really
    /// ended up empty (a same-workspace move, such as a new column, keeps
    /// the tab in it), else lets repairs apply again.
    func finishClosing(_ workspace: WorkspaceModel, moved: Bool) {
        guard let key = workspace.key else { return }
        let repair = repair(for: workspace)
        guard moved, let current = services.workspace(id: workspace.id), current.screens.allSatisfy({ $0.panes.allSatisfy(\.tabs.isEmpty) }),
              let daemon = services.machines.daemon(forWorkspace: workspace.id) else {
            repair.endClosing(key)
            return
        }
        // No terminal to end: every tab moved out.
        daemon.send("close-workspace") { connection in try await WorkspaceClose.close(key, terminals: [], on: connection) }
    }

    /// `moveWorkspaceToNewWindow` / `moveWorkspace`: no tab moves; the
    /// source workspace changes window (and sidebar slot).
    func moveSourceWorkspace(_ outcome: TabDragOutcome, drag: Drag) {
        let id = drag.source.context.sourceWorkspaceID
        switch outcome {
        case .moveWorkspaceToNewWindow(let point):
            let size = drag.source.window?.window?.frame.size ?? drag.source.windowSize
            if let controller = services.windows.openWindow(workspaces: [id], frame: tearOffFrame(drag, at: point, size: size)) {
                services.windows.bringToFront(controller)
            }
        case .moveWorkspace(let group, let index):
            let target = drag.winner?.window ?? drag.source.window
            if let state = target?.state { services.windows.claim(workspaceID: id, in: state) }
            guard let key = services.workspace(id: id)?.key, let daemon = services.machines.daemon(forWorkspace: id) else { return }
            daemon.send("move-workspace") { connection in
                try await TabMoves.place(key, group: group.map(WorkspaceGroupID.init(rawValue:)), index: index, connection: connection)
            }
        default:
            break
        }
    }

    private func repair(for workspace: WorkspaceModel) -> EmptyWorkspaceRepair {
        let machine = services.machines.daemon(forWorkspace: workspace.id)?.machineID
        return machine.flatMap { services.machines.session($0)?.emptyWorkspaces } ?? services.emptyWorkspaces
    }
}
