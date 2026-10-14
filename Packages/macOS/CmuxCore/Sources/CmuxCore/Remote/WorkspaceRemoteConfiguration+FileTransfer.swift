import Foundation

extension WorkspaceRemoteConfiguration {
    /// The SSH `-o` options for copying a file to this workspace's endpoint:
    /// ``sshOptions``, with the agent socket ahead of them because OpenSSH
    /// keeps the first value it reads.
    public var fileTransferSSHOptions: [String] {
        var options = sshOptions
        if let agentSocketPath {
            options.insert("IdentityAgent=" + agentSocketPath, at: 0)
        }
        return options
    }
}
