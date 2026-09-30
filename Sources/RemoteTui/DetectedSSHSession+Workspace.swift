import CmuxCore
import Foundation

extension DetectedSSHSession {
    /// File copy uses the same SSH endpoint; it does not need a PTY-owning daemon.
    init(configuration: WorkspaceRemoteConfiguration) {
        var options = configuration.sshOptions
        if let agent = configuration.agentSocketPath { options.insert("IdentityAgent=" + agent, at: 0) }
        self.init(destination: configuration.destination, port: configuration.port,
                  identityFile: configuration.identityFile, configFile: nil, jumpHost: nil,
                  controlPath: nil, useIPv4: false, useIPv6: false, forwardAgent: false,
                  compressionEnabled: false, sshOptions: options)
    }
}
