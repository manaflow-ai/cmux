import AppKit
import CmuxTerminal
import Foundation
import SwiftUI

extension ContentView {
    func installNotesSessionLoaderIfNeeded() {
        // Register this window's resolver keyed by its TabManager so multiple
        // windows coexist (the static map is searched, not overwritten).
        TerminalSurface.registerWorkspaceNotesDirectoryResolver(owner: tabManager) { [weak tabManager] id in
            // Notes is a beta feature: while it is off, don't export
            // CMUX_WORKSPACE_NOTES_DIR — the variable is what steers agents
            // (the cmux-notes skill) into a notes workflow nothing surfaces.
            guard RightSidebarBetaFeatureSettings.isNotesEnabled() else { return nil }
            guard let tabManager,
                  let workspace = tabManager.tabs.first(where: { $0.id == id }) else { return nil }
            let cwd = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cwd.isEmpty else { return nil }
            let projectRoot = NoteSupport.projectRoot(forCwd: cwd)
            // Never hand agents a notes dir whose trust boundary is a
            // committed symlink (.cmux, .cmux/notes, or the predictable
            // workspace folder itself) — their writes would follow it out.
            guard NoteSupport.projectNotesDirectoryIsTrusted(projectRoot: projectRoot) else { return nil }
            let root = NotesTreeStorage.resolveWorkspaceRoot(
                projectRoot: projectRoot,
                cwd: cwd,
                anchorId: workspace.noteAnchorId
            )
            guard !NotesTreeStorage.isSymlink(root) else { return nil }
            return root
        }
    }

    /// Open a note file from the Notes tree through the exact same path as
    /// Files-tab files (`openFileSurfaces` → markdown viewer for `.md`).
    /// Empty notes (i.e. freshly created ones) open straight in the text
    /// editor with focus — there is nothing to render yet, and a new note is
    /// opened to be written. `editImmediately` forces that for the
    /// name-it-with-Return new-note flow.
    func openNoteFromSidebar(node: NotesTreeNode, editImmediately: Bool) {
        guard case .note = node.kind else { return }
        guard let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        sidebarSelectionState.selection = .tabs
        let panels = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [node.path],
            focus: true,
            reuseExisting: true
        )
        let isEmptyNote = ((try? String(contentsOfFile: node.path, encoding: .utf8)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if editImmediately || isEmptyNote, let markdown = panels.first as? MarkdownPanel {
            markdown.setDisplayMode(.text, focusTextEditor: true)
        }
    }

    /// Resume the agent session backing a Notes session folder by reusing the
    /// shared resume coordinator (any agent: claude, codex, registered, …).
    func resumeNoteSession(marker: NotesSessionMarker) {
        guard let entry = marker.makeSessionEntry() else {
            NSSound.beep()
            return
        }
        SessionEntryResumeCoordinator.resume(entry, tabManager: tabManager)
    }

    func openRightSidebarToolPane(_ mode: RightSidebarMode) {
        guard mode.canOpenAsPane,
              let workspace = tabManager.selectedWorkspace,
              let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            NSSound.beep()
            return
        }

        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        _ = workspace.openOrFocusRightSidebarToolSurface(inPane: paneId, mode: mode, focus: true)
    }

    func openFilePreviewFromSidebar(filePath: String) {
        guard let workspace = tabManager.selectedWorkspace else { return }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }

        sidebarSelectionState.selection = .tabs
        if workspace.isRemoteWorkspace {
            Task { [weak workspace, fileExplorerStore] in
                guard let workspace else { return }
                do {
                    let localURL = try await fileExplorerStore.materializeRemoteFileForPreview(path: filePath)
                    _ = workspace.openFileSurfaces(
                        inPane: paneId,
                        filePaths: [localURL.path],
                        focus: true,
                        reuseExisting: true
                    )
                } catch {
                    NSSound.beep()
                }
            }
            return
        }
        _ = workspace.openFileSurfaces(
            inPane: paneId,
            filePaths: [filePath],
            focus: true,
            reuseExisting: true
        )
    }

    func syncFileExplorerDirectory() {
        guard let selectedId = tabManager.selectedTabId,
              let tab = tabManager.tabs.first(where: { $0.id == selectedId }) else {
            // No selection means we have no local cwd to scope by; clear so the
            // sessions panel doesn't keep filtering by a stale previous tab.
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            notesTreeStore.clear()
            return
        }

        fileExplorerStore.showHiddenFiles = true

        if tab.usesRemoteDirectoryProvenance {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            notesTreeStore.clear()  // Notes is local-only in v1.
            guard shouldSyncFileExplorerStore else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            guard let config = tab.remoteConfiguration, config.transport == .ssh else {
                fileExplorerStore.applyWorkspaceRoot(.none)
                return
            }
            let unavailableDetail = tab.remoteConnectionDetail ?? tab.remoteDaemonStatus.detail

            #if DEBUG
            let hasUnavailableDetail = unavailableDetail?.isEmpty == false
            cmuxDebugLog(
                "fileExplorer.sync remote state=\(tab.remoteConnectionState.rawValue) " +
                "hasDestination=\(config.destination.isEmpty ? 0 : 1) " +
                "hasDisplayTarget=\(config.displayTarget.isEmpty ? 0 : 1) " +
                "hasIdentityFile=\(config.identityFile == nil ? 0 : 1) " +
                "hasDetail=\(hasUnavailableDetail ? 1 : 0)"
            )
            #endif

            fileExplorerStore.applyWorkspaceRoot(
                .remoteSSH(
                    workspaceId: tab.id,
                    connection: SSHFileExplorerConnection(
                        destination: config.destination,
                        port: config.port,
                        identityFile: config.identityFile,
                        sshOptions: config.sshOptions
                    ),
                    displayTarget: config.displayTarget,
                    rootPath: tab.trustedRemoteCurrentDirectory,
                    isAvailable: tab.remoteConnectionState == .connected,
                    unavailableDetail: unavailableDetail
                )
            )
            return
        }

        let dir = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dir.isEmpty else {
            sessionIndexStore.setCurrentDirectoryIfChanged(nil)
            fileExplorerStore.applyWorkspaceRoot(.none)
            notesTreeStore.clear()
            return
        }

        // Notes is local-only and independent of the file-explorer sync gate
        // below, so bind it before that early-returns for non-Files/Find modes.
        // While the Notes beta is off, the store stays unbound: a hidden
        // default-off feature must not cost anyone file watchers or
        // agent/session scanning.
        if RightSidebarBetaFeatureSettings.isNotesEnabled(),
           let workspace = tabManager.selectedWorkspace {
            notesTreeStore.setWorkspace(
                title: workspace.title,
                projectRoot: NoteSupport.projectRoot(forCwd: dir),
                currentDirectory: dir,
                anchorId: workspace.noteAnchorId,
                observedSessions: { [weak workspace] in
                    await workspace?.notesTreeObservedAgentSessions() ?? NotesTreeObservation()
                }
            )
        } else {
            notesTreeStore.clear()
        }

        sessionIndexStore.setCurrentDirectoryIfChanged(dir)
        guard shouldSyncFileExplorerStore else {
            fileExplorerStore.applyWorkspaceRoot(.none)
            return
        }
        fileExplorerStore.applyWorkspaceRoot(.local(workspaceId: tab.id, path: dir))
    }

    private func refreshNotesTerminalRowsForSelectedWorkspace() {
        guard notesBetaEnabled,
              let workspace = tabManager.selectedWorkspace else { return }
        notesTreeStore.applyObservedTerminals(workspace.notesTreeObservedTerminals())
    }

    func handleNotesTerminalMetadataDidChange(_ notification: Notification) {
        guard let workspace = notification.object as? Workspace,
              workspace.id == tabManager.selectedTabId else { return }
        refreshNotesTerminalRowsForSelectedWorkspace()
    }

    var shouldSyncFileExplorerStore: Bool {
        FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
            isRightSidebarVisible: fileExplorerState.isVisible,
            mode: fileExplorerState.mode
        )
    }
}
