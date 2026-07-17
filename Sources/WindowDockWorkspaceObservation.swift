import Foundation
import Observation

/// Narrows workspace observation to state that can affect the window Dock.
@MainActor
@Observable
final class WindowDockWorkspaceObservation {
    private(set) var snapshot: WindowDockWorkspaceSnapshot
    @ObservationIgnored private weak var workspace: Workspace?
    @ObservationIgnored private var observationTasks: [Task<Void, Never>] = []

    init(workspace: Workspace) {
        snapshot = workspace.windowDockWorkspaceSnapshot()
        observe(workspace)
    }

    func observe(_ workspace: Workspace) {
        guard self.workspace !== workspace else { return }
        self.workspace = workspace
        cancelObservationTasks()
        apply(workspace.windowDockWorkspaceSnapshot())

        observationTasks = [
            observe(
                workspace,
                notification: .workspaceCurrentDirectoryDidChange
            ),
            observe(
                workspace,
                notification: .workspaceWindowDockSnapshotDidChange
            ),
        ]
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }

    private func observe(
        _ workspace: Workspace,
        notification name: Notification.Name
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self, weak workspace] in
            guard let workspace else { return }
            for await _ in NotificationCenter.default.notifications(
                named: name,
                object: workspace
            ) {
                guard !Task.isCancelled,
                      let self,
                      self.workspace === workspace else {
                    return
                }
                self.apply(workspace.windowDockWorkspaceSnapshot())
            }
        }
    }

    private func cancelObservationTasks() {
        observationTasks.forEach { $0.cancel() }
        observationTasks.removeAll()
    }

    private func apply(_ next: WindowDockWorkspaceSnapshot) {
        guard snapshot != next else { return }
        snapshot = next
    }
}
