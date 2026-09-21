import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxWorkspacePresence
import Foundation
import Observation

/// Owns one shared workspace-presence session for the Mac's active workspace.
@MainActor @Observable
final class WorkspacePresenceController {
    enum Phase: Equatable { case unavailable, connecting, available }
    private(set) var phase: Phase = .unavailable
    private(set) var activeScope: WorkspacePresenceScope?
    private(set) var participants: [WorkspacePresenceParticipant] = []
    private var auth: AuthCoordinator?
    private var session: WorkspacePresenceSession?
    private var task: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    deinit {
        task?.cancel(); snapshotTask?.cancel(); authTask?.cancel(); observers.forEach(NotificationCenter.default.removeObserver)
    }

    func configure(auth: AuthCoordinator) {
        guard self.auth !== auth else { return }
        self.auth = auth
        authTask?.cancel()
        authTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            for await _ in auth.authenticatedTeamScopes() {
                guard let self, !Task.isCancelled else { return }
                self.restartForAuth()
            }
        }
        if observers.isEmpty {
            observers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated {
                        if note.name == NSApplication.didResignActiveNotification { self?.session?.setViewing(false) }
                        else if self?.activeScope != nil { self?.session?.setViewing(true) }
                    }
                }
            }
        }
        restartForAuth()
    }

    func setActiveWorkspace(_ workspace: Workspace?) { setActiveScope(WorkspacePresenceScope.forWorkspace(workspace)) }

    func setActiveScope(_ scope: WorkspacePresenceScope?) {
        guard scope != activeScope else { session?.setViewing(scope != nil && NSApp.isActive); return }
        activeScope = scope
        task?.cancel(); snapshotTask?.cancel(); session?.stop(); task = nil; snapshotTask = nil; session = nil; participants = []
        guard let scope, let auth, auth.isAuthenticated, let accountID = auth.currentUser?.id,
              let baseURL = PresenceSettings.resolvedURL() else { phase = .unavailable; return }
        let model = WorkspacePresenceSession(transport: WorkspacePresenceWebSocket(baseURL: baseURL))
        session = model; phase = .connecting
        let teamID = scope.teamID
        snapshotTask = Task { @MainActor [weak self, weak auth, model] in
            for await values in model.snapshots() {
                guard let self, self.session === model else { return }
                self.participants = values.map {
                    WorkspacePresenceParticipant(
                        id: $0.id,
                        displayName: $0.displayName,
                        avatarURL: $0.avatarURL,
                        lastSeenAt: Date()
                    )
                }
                self.phase = model.phase == .available ? .available : .unavailable
                if model.phase == .connecting { self.phase = .connecting }
                guard auth?.isAuthenticated == true, auth?.currentUser?.id == accountID else { return }
            }
        }
        task = Task { @MainActor [weak self, weak auth, model] in
            await model.run(scope: scope,
                            accessToken: {
                                guard let auth, auth.isAuthenticated, auth.currentUser?.id == accountID else { return nil }
                                return try? await auth.currentTokens().accessToken
                            },
                            isCurrent: {
                                guard let auth, auth.isAuthenticated, auth.currentUser?.id == accountID,
                                      self?.activeScope == scope else { return false }
                                return teamID == nil || auth.resolvedTeamID == teamID
                            })
            guard let self, self.session === model else { return }
            self.phase = model.phase == .available ? .available : .unavailable
        }
        model.setViewing(NSApp.isActive)
    }

    func collaborators() -> [WorkspacePresenceParticipant] { participants.filter { $0.id != auth?.currentUser?.id } }

    private func restartForAuth() {
        let scope = activeScope
        setActiveScope(nil)
        if auth?.isAuthenticated == true { setActiveScope(scope) }
    }
}

private extension PresenceSettings {
    static func resolvedURL() -> URL? { PresenceHeartbeatClient.resolvedServiceURL() }
}
