import AppKit
import Combine
import SwiftUI

/// A first-class workspace pane that browses, previews, resumes, and deletes the
/// permanent history of AI agent sessions (Claude, Codex, and the other agents
/// surfaced by ``SessionIndexStore``).
///
/// The pane reuses the same ``SessionIndexView`` that powers the right-sidebar
/// "Vault" tool, but is its own ``PanelType`` so it can be opened, persisted, and
/// restored as a dedicated split rather than only as a sidebar mode.
@MainActor
final class HistoryPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .history

    @Published private(set) var focusFlashToken: Int = 0

    private weak var workspace: Workspace?
    private var sessionIndexStoreStorage: SessionIndexStore?
    private var workspaceObservationCancellable: AnyCancellable?

    init(workspace: Workspace) {
        self.id = UUID()
        reattach(to: workspace)
    }

    /// Lazily-created session index store scoped to this pane. Owning a private
    /// store keeps the pane independent of the sidebar's store while reading the
    /// same on-disk session sources.
    var sessionIndexStore: SessionIndexStore {
        if let store = sessionIndexStoreStorage { return store }
        let store = SessionIndexStore()
        sessionIndexStoreStorage = store
        if let workspace {
            syncSessionIndexRoot(from: workspace, store: store)
        }
        return store
    }

    var displayTitle: String {
        String(localized: "history.pane.title", defaultValue: "History")
    }

    var displayIcon: String? { "clock.arrow.circlepath" }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
        observeWorkspaceRootChanges(workspace)
        if let store = sessionIndexStoreStorage {
            syncSessionIndexRoot(from: workspace, store: store)
        }
    }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func close() {
        sessionIndexStoreStorage?.setCurrentDirectoryIfChanged(nil)
        workspaceObservationCancellable = nil
    }

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    private func observeWorkspaceRootChanges(_ workspace: Workspace) {
        workspaceObservationCancellable = Publishers.MergeMany(
            workspace.$currentDirectory.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConfiguration.map { _ in () }.eraseToAnyPublisher(),
            workspace.$remoteConnectionState.map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self, weak workspace] _ in
            Task { @MainActor in
                guard let self, let workspace, let store = self.sessionIndexStoreStorage else { return }
                self.syncSessionIndexRoot(from: workspace, store: store)
            }
        }
    }

    private func syncSessionIndexRoot(from workspace: Workspace, store: SessionIndexStore) {
        guard !workspace.isRemoteWorkspace else {
            store.setCurrentDirectoryIfChanged(nil)
            return
        }

        let directory = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setCurrentDirectoryIfChanged(directory.isEmpty ? nil : directory)
    }
}
