import AppKit
import CmuxAuthRuntime
import CmuxWorkspaceShare
import Foundation
import Observation

@MainActor
final class WorkspaceShareCoordinator {
    private let auth: AuthCoordinator
    private let browserSignIn: HostBrowserSignInFlow
    private let apiClient: WorkspaceShareAPIClient
    private var activeSession: WorkspaceShareHostSession?
    private var activeOwnerUserID: String?
    private var startingOwnerUserID: String?
    private var startTask: Task<Void, Never>?
    private let authObserver = WorkspaceShareAuthObserver()
    private var authStateTask: Task<Void, Never>?

    init(
        auth: AuthCoordinator,
        browserSignIn: HostBrowserSignInFlow,
        serviceURL: URL
    ) {
        self.auth = auth
        self.browserSignIn = browserSignIn
        apiClient = WorkspaceShareAPIClient(baseURL: serviceURL)
        let observer = authObserver
        authStateTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            for await accountID in observer.accountIDs(for: auth) {
                guard let self, !Task.isCancelled else { return }
                if self.startingOwnerUserID != nil, self.startingOwnerUserID != accountID {
                    self.startTask?.cancel()
                    self.startTask = nil
                    self.startingOwnerUserID = nil
                }
                if self.activeSession != nil, self.activeOwnerUserID != accountID {
                    await self.stopActiveSession(revokeRoom: true)
                }
            }
        }
    }

    func share(workspaceID: UUID, tabManager: TabManager) {
        if let activeSession, activeSession.workspaceID == workspaceID {
            activeSession.showChat()
            return
        }
        startTask?.cancel()
        startTask = Task { @MainActor [weak self, weak tabManager] in
            guard let self, let tabManager else { return }
            await self.startShare(workspaceID: workspaceID, tabManager: tabManager)
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        startingOwnerUserID = nil
        Task { @MainActor [weak self] in
            await self?.stopActiveSession(revokeRoom: true)
        }
    }

    private func startShare(workspaceID: UUID, tabManager: TabManager) async {
        await stopActiveSession(revokeRoom: true)
        await auth.awaitBootstrapped()
        guard !Task.isCancelled else { return }
        if !auth.isAuthenticated {
            guard await browserSignIn.signIn(timeout: 10 * 60),
                  auth.isAuthenticated else { return }
        }
        guard !Task.isCancelled,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceID }),
              let ownerUserID = auth.currentUser?.id else { return }
        startingOwnerUserID = ownerUserID
        defer {
            if startingOwnerUserID == ownerUserID {
                startingOwnerUserID = nil
            }
        }

        do {
            let accessToken = try await auth.accessToken()
            guard !Task.isCancelled, auth.currentUser?.id == ownerUserID else { return }
            let sessionInfo = try await apiClient.create(
                workspaceID: workspace.id,
                workspaceTitle: Self.boundedWorkspaceTitle(workspace.customTitle ?? workspace.title),
                accessToken: accessToken
            )
            guard !Task.isCancelled,
                  auth.currentUser?.id == ownerUserID,
                  tabManager.tabs.contains(where: { $0.id == workspaceID }) else {
                try? await apiClient.end(sessionInfo, accessToken: accessToken)
                return
            }
            let hostSession = WorkspaceShareHostSession(
                session: sessionInfo,
                workspace: workspace,
                tabManager: tabManager,
                accessTokenProvider: { [weak auth = self.auth] in
                    guard let auth else { throw WorkspaceShareError.unauthorized }
                    return try await auth.accessToken()
                }
            ) { [weak self] in
                self?.endActiveSession()
            }
            do {
                try await hostSession.start(accessToken: accessToken)
            } catch {
                await hostSession.stop()
                try? await apiClient.end(sessionInfo, accessToken: accessToken)
                throw error
            }
            guard !Task.isCancelled, auth.currentUser?.id == ownerUserID else {
                await hostSession.stop()
                try? await apiClient.end(sessionInfo, accessToken: accessToken)
                return
            }
            activeSession = hostSession
            activeOwnerUserID = ownerUserID
        } catch {
            guard !Task.isCancelled else { return }
            showError(in: tabManager.window)
        }
    }

    private func endActiveSession() {
        Task { @MainActor [weak self] in
            await self?.stopActiveSession(revokeRoom: true)
        }
    }

    private func stopActiveSession(revokeRoom: Bool) async {
        guard let session = activeSession else { return }
        activeSession = nil
        activeOwnerUserID = nil
        await session.stop()
        guard revokeRoom,
              let accessToken = try? await auth.accessToken() else { return }
        try? await apiClient.end(session.session, accessToken: accessToken)
    }

    private func showError(in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "workspaceShare.error.title",
            defaultValue: "Workspace sharing is unavailable"
        )
        alert.informativeText = String(
            localized: "workspaceShare.error.message",
            defaultValue: "Check your connection and try Share Workspace again."
        )
        alert.addButton(withTitle: String(
            localized: "workspaceShare.error.dismiss",
            defaultValue: "OK"
        ))
        if let window, window.isVisible {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private static func boundedWorkspaceTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = String(localized: "workspaceShare.workspace.untitled", defaultValue: "Workspace")
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(160))
    }
}

@MainActor
private final class WorkspaceShareAuthObserver {
    private weak var auth: AuthCoordinator?
    private var continuation: AsyncStream<String?>.Continuation?

    func accountIDs(for auth: AuthCoordinator) -> AsyncStream<String?> {
        stop()
        self.auth = auth
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.stop() }
            }
            observe()
        }
    }

    func stop() {
        let previous = continuation
        continuation = nil
        auth = nil
        previous?.finish()
    }

    private func observe() {
        guard let auth, let continuation else { return }
        let accountID = withObservationTracking {
            auth.isAuthenticated ? auth.currentUser?.id : nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        continuation.yield(accountID)
    }
}
