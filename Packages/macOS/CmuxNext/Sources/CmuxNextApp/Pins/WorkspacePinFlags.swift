import CmuxNextDaemon

/// The `pinned` flag (`workspace-pin-v1`) on each workspace's own daemon, kept with a sidebar-document pin
/// (pinning-DESIGN.md). The document lives on the home daemon; a pin there changed no daemon's flag, so a
/// workspace of another session (the Chief's own session, an SSH or Cloud machine) never read as pinned
/// to its daemon's readers (the TUI, iOS, `cmux workspace list`). Seams: `owner` finds a workspace and its
/// daemon, `supportsPin` reads the capability, `send` writes the flag.
@MainActor
struct WorkspacePinFlags {
    let owner: (String) -> (WorkspaceModel, DaemonService)?
    var supportsPin: (DaemonService) -> Bool = { $0.supports(DaemonCapabilities.shared.workspacePin) }
    let send: (DaemonService, WorkspaceKey, Bool) -> Void

    /// Sets the flag of each workspace in `ids` whose daemon's flag is not `pinned` yet.
    func mirror(_ ids: [String], pinned: Bool) {}
}
