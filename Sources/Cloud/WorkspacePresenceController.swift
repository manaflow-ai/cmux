import AppKit
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import Foundation

extension Notification.Name {
    static let workspacePresenceDidChange = Notification.Name("cmux.workspacePresenceDidChange")
}

/// Bridges foreground selection and mounted Cloud rows to workspace-scoped presence.
@MainActor
final class WorkspacePresenceController {
    private var auth: AuthCoordinator?
    private var roster: WorkspacePresenceRoster?
    private var authTask: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?
    private var bindingTask: Task<Void, Never>?
    private var lifecycleTasks: [Task<Void, Never>] = []
    private var visibleWorkspaces: [UUID: (machineID: String, workspaceID: String)] = [:]
    private weak var selectedWorkspace: Workspace?

    deinit {
        authTask?.cancel()
        changesTask?.cancel()
        bindingTask?.cancel()
        for task in lifecycleTasks { task.cancel() }
    }

    func configure(auth: AuthCoordinator) {
        guard self.auth !== auth else { return }
        self.auth = auth
        authTask?.cancel()
        changesTask?.cancel()
        if let url = PresenceHeartbeatClient.resolvedServiceURL() {
            let roster = WorkspacePresenceRoster(transport: WorkspacePresenceWebSocket(baseURL: url))
            self.roster = roster
            let changes = roster.changes()
            changesTask = Task { @MainActor [weak self] in
                for await scope in changes {
                    guard let self, !Task.isCancelled else { return }
                    NotificationCenter.default.post(name: .workspacePresenceDidChange, object: self, userInfo: ["scope": scope])
                }
            }
        }
        authTask = Task { @MainActor [weak self, weak auth] in
            guard let auth else { return }
            for await _ in auth.authenticatedTeamScopes() {
                guard let self, !Task.isCancelled else { return }
                let identity = auth.authenticatedSessionIdentity
                let teamID = auth.resolvedTeamID
                let current: @MainActor @Sendable () -> Bool = { [weak auth] in
                    guard let auth, let identity else { return false }
                    return auth.authenticatedSessionIdentity == identity && auth.resolvedTeamID == teamID
                }
                self.roster?.configure(accountID: identity?.accountID, teamID: teamID, accessToken: { [weak auth] in
                    guard current(), let auth else { return nil }
                    return try? await auth.currentTokens().accessToken
                }, isCurrent: current)
                self.refreshSelection()
                // Every mounted cell must clear/rebind on account or team changes.
                NotificationCenter.default.post(name: .workspacePresenceDidChange, object: self)
            }
        }
        if lifecycleTasks.isEmpty {
            lifecycleTasks = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                              NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification].map { name in
                let events = NotificationCenter.default.notifications(named: name).map { _ in () }
                return Task { @MainActor [weak self] in
                    for await _ in events {
                        guard let self, !Task.isCancelled else { return }
                        self.refreshSelection()
                    }
                }
            }
        }
        refreshSelection()
    }

    func refreshSelection() {
        let workspace = NSApp.mainWindow == nil ? nil : AppDelegate.shared?.tabManager?.selectedWorkspace
        if workspace !== selectedWorkspace {
            selectedWorkspace = workspace
            bindingTask?.cancel()
            bindingTask = nil
            if let workspace {
                let changes = workspace.cloudBindingState.changes()
                bindingTask = Task { @MainActor [weak self, weak workspace] in
                    for await _ in changes {
                        guard let self, !Task.isCancelled, self.selectedWorkspace === workspace else { return }
                        self.reconcile()
                    }
                }
            }
        }
        reconcile()
    }

    func observeCloudWorkspace(machine: SurfaceMachineID?, workspaceID: String?, owner: UUID) {
        if case .cloud(let machineID) = machine, let workspaceID {
            if let previous = visibleWorkspaces[owner], previous.machineID == machineID, previous.workspaceID == workspaceID { return }
            visibleWorkspaces[owner] = (machineID, workspaceID)
        } else {
            guard visibleWorkspaces.removeValue(forKey: owner) != nil else { return }
        }
        reconcile()
    }

    func collaborators(forCloudMachine machine: SurfaceMachineID, workspaceID: String) -> [CmuxWorkspacePresence.WorkspacePresenceParticipant] {
        guard case .cloud(let machineID) = machine,
              let scope = cloudScope(machineID: machineID, workspaceID: workspaceID) else { return [] }
        return roster?.collaborators(in: scope) ?? []
    }

    private func cloudScope(machineID: String, workspaceID: String) -> WorkspacePresenceScope? {
        guard let teamID = auth?.resolvedTeamID else { return nil }
        return WorkspacePresenceScope(kind: .cloud, ownerID: machineID, workspaceID: workspaceID, teamID: teamID)
    }

    private func reconcile() {
        let observed = Set(visibleWorkspaces.values.compactMap { cloudScope(machineID: $0.machineID, workspaceID: $0.workspaceID) })
        roster?.setWorkspaces(observed: observed, selected: WorkspacePresenceScope.forWorkspace(selectedWorkspace), isActive: NSApp.isActive)
    }
}
