public import CmuxNextDaemon
import Foundation

/// The daemon's capabilities and its socket, for callers that open their own connection.
extension DaemonService {
    public func supports(_ capability: String) -> Bool {
        store.supports(capability)
    }

    /// The socket for dedicated terminal attachments (re-read on reconnect).
    public func endpoint() async throws -> DaemonEndpoint {
        if policyBlock.isBlocked { throw DaemonError.endpointBlocked("turned off by your organization") }
        if connection == nil, startup == .connecting, isStarting { await firstConnection() }
        guard let connection, let endpoint = await connection.endpoint else { throw DaemonError.notConnected }
        return endpoint
    }
}

extension DaemonService {
    /// Keys typed into a terminal being created go to this daemon at once (cx-wb5.78): the local
    /// daemon only, whose give-backs the app listens to.
    public var queuesCreatingInput: Bool { isLocal && supports(DaemonCapability.terminalInputWhileCreating.rawValue) }

    /// The input of a view whose terminal `terminalID` is still being created goes to this daemon
    /// by that id until `targetKnown` (cx-wb5.78); nil when the daemon does not queue such input.
    public func creatingInput(_ terminalID: TerminalID?, targetKnown: @escaping @Sendable () -> Bool) -> CreatingTerminalInput? {
        guard let id = terminalID?.rawValue, let connection, queuesCreatingInput else { return nil }
        return CreatingTerminalInput(terminalID: id, connection: connection, targetKnown: targetKnown)
    }
}

/// Which machine this service reaches.
extension DaemonService {
    public var isLocal: Bool { machineID == "local" }

    /// Directory new terminals start in: the Mac's home for the local
    /// daemon; nil (the machine's own default) on a Cloud machine, where a
    /// Mac path does not exist.
    public var defaultCwd: String? { isLocal ? NSHomeDirectory() : nil }
}
