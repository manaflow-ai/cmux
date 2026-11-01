public import CmuxNextDaemon
import Foundation

/// The daemon's capabilities, its control connection and its socket.
extension DaemonService {
    /// The current (or last) daemon's identity. The store owns it and
    /// replaces it on every handshake, so capabilities follow a daemon that
    /// restarted or was handed off to a newer build after the first connect.
    public var identity: DaemonIdentity? { store.identity }

    public func supports(_ capability: String) -> Bool {
        store.supports(capability)
    }

    /// The socket for callers that open a connection of their own (re-read on reconnect).
    public func endpoint() async throws -> DaemonEndpoint {
        guard let endpoint = try await machineConnection().endpoint else { throw DaemonError.notConnected }
        return endpoint
    }

    /// This machine's control connection, which its terminal views attach on (`TerminalAttachment.attach(on:)`):
    /// as streams when the connection streams terminals, else each on a connection of its own to
    /// the connection's current endpoint. Waits for the first connect while the service starts.
    public func machineConnection() async throws -> DaemonConnection {
        if policyBlock.isBlocked { throw DaemonError.endpointBlocked("turned off by your organization") }
        if connection == nil, startup == .connecting, isStarting { await firstConnection() }
        guard let connection else { throw DaemonError.notConnected }
        return connection
    }
}

extension DaemonService {
    /// Keys typed into a terminal being created go to this daemon at once (cx-wb5.78): the local
    /// daemon only, whose give-backs the app listens to.
    public var queuesCreatingInput: Bool { isLocal && supports(DaemonCapability.terminalInputWhileCreating.rawValue) }

    /// ``queuesCreatingInput`` for a create on pane `target`. A create on a stand-in (Cmd-N's first pane, a split still in
    /// flight) waits for the daemon's pane before it is sent (`DaemonStore.daemonTarget`, #29530), so the daemon does not know
    /// its terminal id yet and refuses keys sent by it: those keys wait in the creation hold for the daemon's terminal, as
    /// on feat-cmux-next (#30271: after Cmd-N then Ctrl-`, the line typed into the stand-in never reached the terminal).
    public func queuesCreatingInput(on target: PaneID) -> Bool { queuesCreatingInput && !ProvisionalPane.isStandIn(target) }

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
