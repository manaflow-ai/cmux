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
        for session in sessions {
            let credential = VNCSessionCredentialProvider.credential(for: session, manifest: manifest)
            launchSessions.append(MacfleetVNCLaunchSession(session: session, credential: credential))
        }
        return .sessions(launchSessions)
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
        case .sessions(let launchSessions):
            openMacfleetVNCWorkspaces(launchSessions: launchSessions)
        }
    }

    @MainActor
    private func openMacfleetVNCWorkspaces(
        launchSessions: [MacfleetVNCLaunchSession]
    ) {
        var firstWorkspace: Workspace?
        var reusedPanels: [(workspace: Workspace, panelId: UUID)] = []
        var credentialSummary = MacfleetVNCLaunchCredentialSummary(skippedCredentialCount: 0)

        for launchSession in launchSessions {
            if let existingWorkspace = existingVNCWorkspace(for: launchSession.session) {
                firstWorkspace = firstWorkspace ?? existingWorkspace
                if let panel = existingWorkspace.vncPanel(matchingConnectionIdentity: launchSession.session) {
                    reusedPanels.append((existingWorkspace, panel.id))
                }
                credentialSummary.reusedCount += 1
                continue
            }

            guard let credential = launchSession.credential else {
                credentialSummary.skippedCredentialCount += 1
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
            if openVNCSession(launchSession.session, credential: credential, in: workspace) {
                firstWorkspace = firstWorkspace ?? workspace
                credentialSummary.openedCount += 1
            } else {
                tabManager.closeWorkspace(workspace)
            }
        }

        if let firstWorkspace {
            tabManager.selectWorkspace(firstWorkspace)
            for reusedPanel in reusedPanels where reusedPanel.workspace.id == firstWorkspace.id {
                reusedPanel.workspace.triggerFocusFlash(panelId: reusedPanel.panelId)
            }
        }

        switch credentialSummary.alert {
        case .none:
            break
        case .noCredentials:
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetNoCredentialsMessage
            )
        case .partial(let openedCount, let reusedCount, let missingCount):
            presentMacfleetVNCAlert(
                title: VNCPanelText.macfleetOpenFailedTitle,
                message: VNCPanelText.macfleetPartialCredentialsMessage(
                    openedCount: openedCount,
                    reusedCount: reusedCount,
                    missingCount: missingCount
                )
            )
        }
    }

    private enum MacfleetVNCLaunchResult: Sendable {
        case manifestMissing
        case manifestFailed
        case noSessions
        case sessions([MacfleetVNCLaunchSession])
    }

    private struct MacfleetVNCLaunchSession: Sendable {
        var session: MacfleetVNCSession
        var credential: VNCResolvedCredential?
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

enum MacfleetVNCLaunchCredentialAlert: Equatable, Sendable {
    case none
    case noCredentials
    case partial(openedCount: Int, reusedCount: Int, missingCount: Int)
}

struct MacfleetVNCLaunchCredentialSummary: Equatable, Sendable {
    var openedCount = 0
    var reusedCount = 0
    var skippedCredentialCount: Int

    var availableWorkspaceCount: Int {
        openedCount + reusedCount
    }

    var alert: MacfleetVNCLaunchCredentialAlert {
        guard skippedCredentialCount > 0 else {
            return .none
        }
        guard availableWorkspaceCount > 0 else {
            return .noCredentials
        }
        return .partial(
            openedCount: openedCount,
            reusedCount: reusedCount,
            missingCount: skippedCredentialCount
        )
    }
}
