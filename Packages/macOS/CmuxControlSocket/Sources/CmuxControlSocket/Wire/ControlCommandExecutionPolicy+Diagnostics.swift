extension ControlCommandExecutionPolicy {
    /// The v1 diagnostic-read family. These commands await actor-owned
    /// diagnostic snapshots, so they run on the socket worker and are not
    /// callable from the main thread.
    static let diagnosticReadV1Commands: Set<String> = [
        "iroh_diag",
        // Graduation P4 dev verbs (DEBUG-only surfaces): same actor-owned
        // await shape as iroh_diag, so same worker policy.
        "next_transport_ticket",
        "next_transport_grant",
    ]

}
