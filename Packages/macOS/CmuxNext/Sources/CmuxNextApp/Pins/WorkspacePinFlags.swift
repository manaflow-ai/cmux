import CmuxNextDaemon

/// The `pinned` flag (`workspace-pin-v1`) on each workspace's own daemon, kept with a sidebar-document pin
/// (pinning-DESIGN.md). The document lives on the home daemon; a pin there changed no daemon's flag, so a
/// workspace of another session (the Chief's own session, an SSH or Cloud machine) never read as pinned
/// to its daemon's readers (the TUI, iOS, `cmux workspace list`). Seams: `owner` finds a workspace and its
/// daemon, `supportsPin` reads the capability, `send` writes the flag.
@MainActor
struct WorkspacePinFlags {
    let owner: (String) -> (WorkspaceModel, DaemonService)?
    var supportsPin: (DaemonService) -> Bool = { $0.supports(DaemonCapability.workspacePin.rawValue) }
    let send: (DaemonService, WorkspaceKey, Bool) -> Void

    /// The app's flags: each workspace's daemon in `machines`, written with `set-workspace-metadata`.
    static func live(_ machines: MachineRegistry) -> WorkspacePinFlags {
        WorkspacePinFlags(owner: { machines.workspace(id: $0) }, send: { daemon, key, pinned in
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, pinned: pinned) }
        })
    }

    /// Sets the flag of each workspace in `ids` whose daemon's flag is not `pinned` yet.
    func mirror(_ ids: [String], pinned: Bool) {
        for id in ids {
            guard let (workspace, daemon) = owner(id), let key = workspace.key, workspace.pinned != pinned, supportsPin(daemon) else { continue }
            send(daemon, key, pinned)
        }
    }
}
