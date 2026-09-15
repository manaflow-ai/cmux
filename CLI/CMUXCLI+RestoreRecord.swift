import CMUXAgentLaunch

extension CMUXCLI {
    /// The socket continuation payload after validation and typed decoding.
    struct RestoreRecord: Sendable {
        let mode: String
        let kind: String
        let checkpointID: String?
        let source: String?
        let workingDirectory: String?
        let environment: [String: String]
        let launchCommand: AgentLaunchCommand?
        let preparedArguments: [String]?
        let preparedArgumentsWorkingDirectory: String?
        let forkArguments: [String]?
        let forkArgumentsWorkingDirectory: String?
        let permissionMode: String?
        let legacyCommand: String?
        let legacyForkCommand: String?

        /// Compatibility alias matching the wire field name `fork_command`.
        var forkCommand: String? { legacyForkCommand }

        func repairingHermesCheckpoint(
            _ checkpointID: String,
            fallbackLaunchCommand: AgentLaunchCommand?
        ) -> RestoreRecord {
            RestoreRecord(
                mode: mode,
                kind: kind,
                checkpointID: checkpointID,
                source: source,
                workingDirectory: workingDirectory,
                environment: environment,
                launchCommand: launchCommand ?? fallbackLaunchCommand,
                preparedArguments: nil,
                preparedArgumentsWorkingDirectory: nil,
                // The recovered identity replaces the old checkpoint, so any
                // precomputed fork argv that embeds it must be rebuilt by the
                // planner from the repaired launch command.
                forkArguments: nil,
                forkArgumentsWorkingDirectory: nil,
                permissionMode: permissionMode,
                legacyCommand: legacyCommand,
                // A compatibility fork command also embeds the superseded
                // checkpoint; never replay it after Hermes identity recovery.
                legacyForkCommand: nil
            )
        }
    }
}
