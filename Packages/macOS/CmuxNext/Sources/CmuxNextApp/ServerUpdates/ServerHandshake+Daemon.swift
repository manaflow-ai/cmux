import CmuxNextDaemon
import CmuxNextUpdater

extension ServerHandshake {
    /// A cmux-tui handshake from its `identify` reply. A cmux-tui restart keeps every terminal.
    init(daemon identity: DaemonIdentity, host: ServerHost) {
        self.init(kind: .cmuxTUI, host: host, build: identity.buildCommit, protocolVersion: identity.protocolVersion,
                  capabilities: Set(identity.capabilities), keepsWorkAcrossRestart: true,
                  version: identity.version)
    }

    /// The optional capabilities this app uses and its bundled cmux-tui serves.
    static var appCmuxTUICapabilities: Set<String> {
        Set(DaemonCapability.optional).subtracting(DaemonCapability.unservedByBundledDaemon)
    }
}
