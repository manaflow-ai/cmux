import AppKit
import CMUXVNC
import Foundation

extension ContentView {
    @MainActor
    func openMacfleetVNCWorkspaces() {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/macfleet/hosts.json")
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.loadMacfleetVNCLaunchResult(from: manifestURL)
            }.value
            openMacfleetVNCWorkspaces(with: result)
        }
    }

    nonisolated private static func loadMacfleetVNCLaunchResult(from manifestURL: URL) -> MacfleetVNCLaunchResult {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return .manifestMissing
        }

        let manifest: MacfleetManifest
        do {
            manifest = try MacfleetManifest.load(from: manifestURL)
        } catch {
            return .manifestFailed
        }

        let sessions = manifest.expandedSessions()
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        guard !sessions.isEmpty else {
            return .noSessions
        }

        var launchSessions: [MacfleetVNCLaunchSession] = []
        var skippedCredentialCount = 0
        for session in sessions {
            guard let credential = VNCSessionCredentialProvider.credential(for: session, manifest: manifest) else {
                skippedCredentialCount += 1
                continue
            }
            launchSessions.append(MacfleetVNCLaunchSession(session: session, credential: credential))
        }
        return .sessions(launchSessions, skippedCredentialCount: skippedCredentialCount)
    }

    @MainActor
    private func openMacfleetVNCWorkspaces(with result: MacfleetVNCLaunchResult) {
        switch result {
        case .manifestMissing:
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetManifestMissingTitle,
                message: VNCPanelText.macfleetManifestMissingMessage
            )
            return
        case .manifestFailed:
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetManifestFailedMessage
            )
            return
        case .noSessions:
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetNoSessionsMessage
            )
            return
        case .sessions(let launchSessions, let skippedCredentialCount):
            openMacfleetVNCWorkspaces(
                launchSessions: launchSessions,
                skippedCredentialCount: skippedCredentialCount
            )
        }
    }

    @MainActor
    private func openMacfleetVNCWorkspaces(
        launchSessions: [MacfleetVNCLaunchSession],
        skippedCredentialCount: Int
    ) {
        var firstWorkspace: Workspace?
        var openedCount = 0

        for launchSession in launchSessions {
            if let existingWorkspace = existingVNCWorkspace(for: launchSession.session) {
                firstWorkspace = firstWorkspace ?? existingWorkspace
                continue
            }

            let workspace = tabManager.addWorkspace(
                title: launchSession.session.workspaceTitle,
                inheritWorkingDirectory: false,
                select: false,
                eagerLoadTerminal: false,
                autoWelcomeIfNeeded: false
            )
            workspace.setCustomDescription(VNCPanelText.workspaceDescription(sessionName: launchSession.session.name))
            if openVNCSession(launchSession.session, credential: launchSession.credential, in: workspace) {
                firstWorkspace = firstWorkspace ?? workspace
                openedCount += 1
            } else {
                tabManager.closeWorkspace(workspace)
            }
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

    private enum MacfleetVNCLaunchResult: Sendable {
        case manifestMissing
        case manifestFailed
        case noSessions
        case sessions([MacfleetVNCLaunchSession], skippedCredentialCount: Int)
    }

    private struct MacfleetVNCLaunchSession: Sendable {
        var session: MacfleetVNCSession
        var credential: VNCResolvedCredential
    }

    @MainActor
    private func openVNCSession(
        _ session: MacfleetVNCSession,
        credential: VNCResolvedCredential,
        in workspace: Workspace
    ) -> Bool {
        guard let paneId = workspace.bonsplitController.focusedPaneId
            ?? workspace.bonsplitController.allPaneIds.first else {
            return false
        }
        let initialPanelId = workspace.focusedPanelId
        guard workspace.newVNCSurface(
            inPane: paneId,
            session: session,
            credential: credential,
            focus: true
        ) != nil else {
            return false
        }
        if let initialPanelId {
            _ = workspace.closePanel(initialPanelId, force: true)
        }
        return true
    }

    @MainActor
    private func existingVNCWorkspace(for session: MacfleetVNCSession) -> Workspace? {
        tabManager.tabs.first { workspace in
            workspace.containsVNCSessionConnectionIdentity(session)
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
