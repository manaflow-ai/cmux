import AppKit
import CMUXVNC
import Foundation

extension ContentView {
    @MainActor
    func openMacfleetVNCWorkspaces() {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macfleet/hosts.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetManifestMissingTitle,
                message: VNCPanelText.macfleetManifestMissingMessage
            )
            return
        }

        let manifest: MacfleetManifest
        do {
            manifest = try MacfleetManifest.load(from: manifestURL)
        } catch {
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetManifestFailed(error.localizedDescription)
            )
            return
        }

        let sessions = manifest.expandedSessions()
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        guard !sessions.isEmpty else {
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetNoSessionsMessage
            )
            return
        }

        var firstWorkspace: Workspace?
        var openedCount = 0
        var skippedCredentialCount = 0

        for session in sessions {
            if let existingWorkspace = existingVNCWorkspace(for: session) {
                firstWorkspace = firstWorkspace ?? existingWorkspace
                continue
            }

            guard let credential = VNCCredentialResolver.resolve(
                session: session,
                keychainPassword: VNCKeychainCredentialProvider.password(for: session)
            ) else {
                skippedCredentialCount += 1
                continue
            }

            let workspace = tabManager.addWorkspace(
                title: session.workspaceTitle,
                inheritWorkingDirectory: false,
                select: false,
                eagerLoadTerminal: false,
                autoWelcomeIfNeeded: false
            )
            workspace.setCustomDescription(VNCPanelText.workspaceDescription(sessionName: session.name))
            openVNCSession(session, credential: credential, in: workspace)
            firstWorkspace = firstWorkspace ?? workspace
            openedCount += 1
        }

        if let firstWorkspace {
            tabManager.selectWorkspace(firstWorkspace)
        }

        if openedCount == 0, firstWorkspace == nil, skippedCredentialCount > 0 {
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetNoCredentialsMessage
            )
            return
        }

        if openedCount > 0, skippedCredentialCount > 0 {
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetPartialCredentialsMessage(
                    openedCount: openedCount,
                    missingCount: skippedCredentialCount
                )
            )
        }
    }

    @MainActor
    private func openVNCSession(
        _ session: MacfleetVNCSession,
        credential: VNCResolvedCredential,
        in workspace: Workspace
    ) {
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return
        }
        let initialPanelId = workspace.focusedPanelId
        guard workspace.newVNCSurface(
            inPane: paneId,
            session: session,
            credential: credential,
            focus: true
        ) != nil else {
            return
        }
        if let initialPanelId {
            _ = workspace.closePanel(initialPanelId, force: true)
        }
    }

    @MainActor
    private func existingVNCWorkspace(for session: MacfleetVNCSession) -> Workspace? {
        tabManager.tabs.first { workspace in
            workspace.title == session.workspaceTitle &&
                workspace.bonsplitController.allTabIds.contains { tabId in
                    guard let panelId = workspace.panelIdFromSurfaceId(tabId),
                          let panel = workspace.vncPanel(for: panelId) else {
                        return false
                    }
                    return panel.session == session
                }
        }
    }

    @MainActor
    private func presentMacfleetVNCAlert(title: String, message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: VNCPanelText.alertOK)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
