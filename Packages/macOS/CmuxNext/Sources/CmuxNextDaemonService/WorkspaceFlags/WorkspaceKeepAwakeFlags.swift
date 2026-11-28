public import CmuxNextDaemon

/// Keep Workspace Awake on each workspace's own daemon (`keep_awake`, `workspace-keep-awake-v1`), so the daemon's
/// freeing timer (cmux-tui `mux/idle_freeing.rs`) keeps the shells this Mac's planner keeps. The person's set stays
/// `WorkspaceKeepAwakeStore`; this writes only a daemon whose flag differs. Seams as in `WorkspacePinFlags`.
@MainActor
public struct WorkspaceKeepAwakeFlags {
    public let owner: (String) -> (WorkspaceModel, DaemonService)?
    public var supportsKeepAwake: (DaemonService) -> Bool
    public let send: (DaemonService, WorkspaceKey, Bool) -> Void

    public init(owner: @escaping (String) -> (WorkspaceModel, DaemonService)?,
                supportsKeepAwake: @escaping (DaemonService) -> Bool = { $0.supports(DaemonCapability.workspaceKeepAwake.rawValue) },
                send: @escaping (DaemonService, WorkspaceKey, Bool) -> Void) {
        self.owner = owner
        self.supportsKeepAwake = supportsKeepAwake
        self.send = send
    }

    /// The app's flags: `owner` finds each workspace's daemon (the App's `MachineRegistry.workspace(id:)`),
    /// written with `set-workspace-metadata`.
    public static func live(owner: @escaping (String) -> (WorkspaceModel, DaemonService)?) -> WorkspaceKeepAwakeFlags {
        WorkspaceKeepAwakeFlags(owner: owner, send: { daemon, key, keptAwake in
            daemon.send("set-workspace-metadata") { _ = try await $0.setWorkspaceMetadata(key, keepAwake: keptAwake) }
        })
    }

    /// Sets the flag of each workspace in `ids` whose daemon's flag is not `keptAwake` yet.
    public func mirror(_ ids: Set<String>, keptAwake: Bool) {
        for id in ids {
            guard let (workspace, daemon) = owner(id), let key = workspace.key, workspace.keepAwake != keptAwake,
                  supportsKeepAwake(daemon) else { continue }
            send(daemon, key, keptAwake)
        }
    }
}
