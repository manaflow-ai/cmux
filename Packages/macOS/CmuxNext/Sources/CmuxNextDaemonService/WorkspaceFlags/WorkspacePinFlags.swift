public import CmuxNextDaemon

/// The `pinned` flag (`workspace-pin-v1`) on each workspace's own daemon, kept with a sidebar-document pin
/// (pinning-DESIGN.md). The document lives on the home daemon; a pin there changed no daemon's flag, so a
/// workspace of another session (the Chief's own session, an SSH or Cloud machine) never read as pinned
/// to its daemon's readers (the TUI, iOS, `cmux workspace list`). Seams: `owner` finds a workspace and its
/// daemon, `supportsPin` reads the capability, `send` writes the flag.
@MainActor
public struct WorkspacePinFlags {
    public let owner: (String) -> (WorkspaceModel, DaemonService)?
    public var supportsPin: (DaemonService) -> Bool
    public let send: (DaemonService, WorkspaceKey, Bool) -> Void

    public init(owner: @escaping (String) -> (WorkspaceModel, DaemonService)?,
                supportsPin: @escaping (DaemonService) -> Bool = { $0.supports(DaemonCapability.workspacePin.rawValue) },
                send: @escaping (DaemonService, WorkspaceKey, Bool) -> Void) {
        self.owner = owner
        self.supportsPin = supportsPin
        self.send = send
    }

    /// The app's flags: `owner` finds each workspace's daemon (the App's `MachineRegistry.workspace(id:)`),
    /// written with `set-workspace-metadata`.
    public static func live(owner: @escaping (String) -> (WorkspaceModel, DaemonService)?) -> WorkspacePinFlags {
        WorkspacePinFlags(owner: owner, send: { daemon, key, pinned in
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, pinned: pinned) }
        })
    }

    /// Sets the flag of each workspace in `ids` whose daemon's flag is not `pinned` yet.
    public func mirror(_ ids: [String], pinned: Bool) {
        for id in ids {
            guard let (workspace, daemon) = owner(id), let key = workspace.key, workspace.pinned != pinned, supportsPin(daemon) else { continue }
            send(daemon, key, pinned)
        }
    }
}
