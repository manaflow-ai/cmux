import CmuxFoundation
import Foundation

extension CMUXCLI {
    struct SSHCommandOptions {
        let destination: String
        let displayDestination: String
        let port: Int?
        let identityFile: String?
        let workspaceName: String?
        let initialCommand: String?
        let windowRaw: String?
        let noFocus: Bool
        var sshOptions: [String]
        let extraArguments: [String]
        let terminalTransport: WorkspaceRemoteTerminalTransport
        let terminalProfile: WorkspaceRemoteTerminalProfile
        let agentSocketPath: String?
        let passwordCredential: String?
        let localSocketPath: String
        let remoteRelayPort: Int
        let pinWorkspaceToTop: Bool
        let daemonWebSocketEndpoint: VMDaemonWebSocketEndpoint?
        /// True when the remote is a cloud VM with cmuxd-remote pre-baked in the image.
        /// Set by `cmux vm new/shell/attach`; false for plain `cmux ssh`.
        let skipDaemonBootstrap: Bool

        init(
            destination: String,
            displayDestination: String? = nil,
            port: Int?,
            identityFile: String?,
            workspaceName: String?,
            initialCommand: String? = nil,
            windowRaw: String? = nil,
            noFocus: Bool,
            sshOptions: [String],
            extraArguments: [String],
            terminalTransport: WorkspaceRemoteTerminalTransport = .ssh,
            terminalProfile: WorkspaceRemoteTerminalProfile = .shell,
            agentSocketPath: String? = nil,
            passwordCredential: String? = nil,
            localSocketPath: String,
            remoteRelayPort: Int,
            pinWorkspaceToTop: Bool = false,
            daemonWebSocketEndpoint: VMDaemonWebSocketEndpoint? = nil,
            skipDaemonBootstrap: Bool = false
        ) {
            self.destination = destination
            self.displayDestination = displayDestination ?? destination
            self.port = port
            self.identityFile = identityFile
            self.workspaceName = workspaceName
            self.initialCommand = initialCommand
            self.windowRaw = windowRaw
            self.noFocus = noFocus
            self.sshOptions = sshOptions
            self.extraArguments = extraArguments
            self.terminalTransport = terminalTransport
            self.terminalProfile = terminalProfile
            self.agentSocketPath = agentSocketPath
            self.passwordCredential = passwordCredential
            self.localSocketPath = localSocketPath
            self.remoteRelayPort = remoteRelayPort
            self.pinWorkspaceToTop = pinWorkspaceToTop
            self.daemonWebSocketEndpoint = daemonWebSocketEndpoint
            self.skipDaemonBootstrap = skipDaemonBootstrap
        }
    }
}
