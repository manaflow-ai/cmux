extension ControlCommandExecutionPolicy {
    /// The v1 diagnostic-read family. These commands await actor-owned
    /// diagnostic snapshots, so they run on the socket worker and are not
    /// callable from the main thread.
    static let diagnosticReadV1Commands: Set<String> = [
        "iroh_diag",
        "debug_agent_manifest",
    ]

    /// Configuration commands that block their socket worker until the main
    /// actor commits the requested runtime update.
    static let configurationMutationV1Commands: Set<String> = [
        "reload_config",
        "reload_agent_manifests",
    ]
}
