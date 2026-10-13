import Foundation

extension WorkspaceRemoteConfiguration {
    /// The workspace's SSH options as `ssh`, `scp` and `sftp` accept them.
    ///
    /// ``sshOptions`` can hold cmux's private route marker, which a `cmux ssh`
    /// handoff leaves there for the code that picks a shared connection. It is
    /// not an OpenSSH option, and OpenSSH refuses an option it does not know,
    /// so anything that writes these out as `-o` arguments reads them here.
    public var openSSHOptions: [String] {
        sshOptions
    }

    /// The SSH `-o` options for copying a file to this workspace's endpoint:
    /// ``openSSHOptions``, with the agent socket ahead of them because OpenSSH
    /// keeps the first value it reads.
    public var fileTransferSSHOptions: [String] {
        var options = openSSHOptions
        if let agentSocketPath {
            options.insert("IdentityAgent=" + agentSocketPath, at: 0)
        }
        return options
    }
}
