import CMUXAgentLaunch

extension CMUXCLI {
    /// The socket restore payload after validation and typed decoding.
    struct RestoreRecord {
        let mode: String
        let kind: String
        let checkpointID: String?
        let source: String?
        let workingDirectory: String?
        let environment: [String: String]
        let launchCommand: AgentLaunchCommand?
        let preparedArguments: [String]?
        let preparedArgumentsWorkingDirectory: String?
        let permissionMode: String?
        let legacyCommand: String?
    }
}
