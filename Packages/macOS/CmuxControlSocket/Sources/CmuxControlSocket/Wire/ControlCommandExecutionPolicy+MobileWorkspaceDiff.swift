extension ControlCommandExecutionPolicy {
    /// Mobile diff reads wait for bounded git subprocesses and filesystem I/O,
    /// so the socket worker owns their deadlines instead of blocking main.
    /// Their implementations hop to main only for workspace resolution, then
    /// run git from a detached utility task. They intentionally remain absent
    /// from `mainThreadCallableSocketWorkerMethods`.
    static var mobileWorkspaceDiffSocketWorkerMethods: Set<String> {
        [
            "mobile.workspace.diff_status",
            "mobile.workspace.diff_file",
        ]
    }
}
