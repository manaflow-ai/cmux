import CmuxNextBrowser
import CmuxNextDaemon
import Foundation

/// Workspace and room browser profiles and the cascade for new tabs
/// (explicit > workspace > room > default; data-model.md 5).
extension BrowserProfileService {
    /// A workspace qualified by its session: the key of personal state and
    /// of the file's fallback defaults.
    struct QualifiedWorkspace: Hashable {
        var session: String
        var key: String
        var fileKey: String { session + "|" + key }
    }

    func qualified(_ workspaceID: String) -> QualifiedWorkspace? {
        guard let (workspace, daemon) = services.machines.workspace(id: workspaceID) else { return nil }
        return QualifiedWorkspace(session: daemon.store.registryID ?? daemon.machineID, key: workspace.key?.rawValue ?? workspace.id)
    }

    /// Whether the home daemon holds personal state (`profiles-v1`).
    var usesPersonalState: Bool {
        let home = services.machines.local.store
        return home.supportsProfiles && home.personal.isLoaded
    }

    /// The workspace's own browser profile, nil when it has none.
    func workspaceDefault(_ workspaceID: String?) -> String? {
        guard let workspaceID, let qualified = qualified(workspaceID) else { return nil }
        if usesPersonalState,
           let id = services.machines.local.store.personal.workspace(session: qualified.session, key: qualified.key)?.browserProfileID {
            return id.rawValue
        }
        return book.workspaceDefaults[qualified.fileKey]
    }

    /// The room a new tab of `workspaceID` takes its default from: the room
    /// of the window that shows it, else the active window's.
    func roomDefault(_ workspaceID: String?) -> String? {
        guard let windows = services.windows else { return nil }
        let owner = workspaceID.flatMap { windows.registry.value.owner(of: $0) }
        let room = owner.flatMap { windows.states[$0]?.profileID } ?? windows.active?.state.profileID ?? .defaultProfile
        return services.machines.local.store.profile(room)?.browserProfileID?.rawValue
    }

    /// Whether a tab may be created in `id`: a record exists here.
    func isKnown(_ id: String) -> Bool { book.contains(id) }

    /// The profile a new tab of `workspaceID` gets without an explicit choice.
    func effectiveProfile(forWorkspace workspaceID: String?) -> String {
        BrowserProfileCascade.resolve(explicit: nil, workspace: workspaceDefault(workspaceID), room: roomDefault(workspaceID), known: isKnown)
    }

    /// The profile a new tab in `pane` gets: `explicit` when it names a
    /// known profile, else the workspace's, the room's, or `default`.
    func profileForNewTab(in pane: PaneID, on daemon: DaemonService, explicit: String?) -> String {
        let workspace = daemon.store.workspace(containing: pane)?.id
        return BrowserProfileCascade.resolve(explicit: explicit, workspace: workspaceDefault(workspace), room: roomDefault(workspace),
                                             known: isKnown)
    }

    /// Sets (nil clears) a workspace's browser profile: in the home daemon's
    /// personal state when it has it, else in the file.
    func setWorkspaceDefault(_ id: String?, for workspaceID: String) throws {
        guard let qualified = qualified(workspaceID) else { throw ActionFailure.invalidTarget(RefusalStrings.noWorkspaceToActOn) }
        try setWorkspaceDefault(id, for: qualified)
    }

    /// `setWorkspaceDefault` for a workspace no snapshot reported yet (one
    /// this app is creating).
    func setWorkspaceDefault(_ id: String?, for qualified: QualifiedWorkspace) throws {
        if usesPersonalState {
            let update: FieldUpdate<BrowserProfileKey> = id.map { .set(BrowserProfileKey(rawValue: $0)) } ?? .clear
            let request = SetPersonalWorkspaceRequest(sessionID: qualified.session, workspaceKey: WorkspaceKey(rawValue: qualified.key),
                                                      browserProfileID: update)
            services.machines.local.send("set-personal-workspace") { try await $0.setPersonalWorkspace(request) }
        }
        try edit { $0.workspaceDefaults[qualified.fileKey] = usesPersonalState ? nil : id }
    }

    /// Workspaces whose browser profile is `id` (file and personal state).
    func workspacesUsing(_ id: String) -> [QualifiedWorkspace] {
        var found = book.workspaceDefaults.filter { $0.value == id }.compactMap { entry -> QualifiedWorkspace? in
            let parts = entry.key.split(separator: "|", maxSplits: 1).map(String.init)
            return parts.count == 2 ? QualifiedWorkspace(session: parts[0], key: parts[1]) : nil
        }
        if usesPersonalState {
            found += services.machines.local.store.personal.workspaces.filter { $0.browserProfileID?.rawValue == id }
                .map { QualifiedWorkspace(session: $0.sessionID, key: $0.workspaceKey.rawValue) }
        }
        return found
    }
}
