import Foundation

extension CloudTuiCommandLine {
    /// The daemon rejects a stale callback or a callback that would replace a user name.
    static func agentRenameArguments(
        socketPath: String, context: CloudAgentNameContext, name: String
    ) -> [String] {
        renameTabArguments(socketPath: socketPath, tabID: context.projection.remoteTabID ?? "", name: name)
            + ["--workspace", context.projection.remoteWorkspaceID ?? "",
               "--source", "auto", "--expected-generation", context.generation,
               "--expected-name-revision", String(context.nameRevision)]
    }
}
