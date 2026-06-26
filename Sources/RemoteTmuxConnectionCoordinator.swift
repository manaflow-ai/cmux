import Foundation

/// Manages the lifecycle of `tmux -CC` control connections: attaching (reusing a
/// live connection for the same host+session), the ready-gated stream attach with
/// a synchronous BatchMode auth/session preflight, and the per-host+session
/// connection lookup.
///
/// Owned by ``RemoteTmuxController`` and constructed with the controller's shared
/// ``RemoteTmuxControlConnectionRegistry`` and ``RemoteTmuxTransportRegistry``
/// (both reference types), so the coordinator reads and re-keys exactly the same
/// live connection state the controller does and reaches each endpoint's
/// ``RemoteTmuxSSHTransport`` through the same registry. `@MainActor` to match the
/// controller's isolation; it holds no UI/AppDelegate state, only the two injected
/// registries.
@MainActor
final class RemoteTmuxConnectionCoordinator {
    /// Live `tmux -CC` control connections keyed `connectionHash\u{1}session`,
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let connectionRegistry: RemoteTmuxControlConnectionRegistry

    /// Per-endpoint SSH transports (keyed by ``RemoteTmuxHost/connectionHash``),
    /// shared with (and owned by) ``RemoteTmuxController``.
    private let transportRegistry: RemoteTmuxTransportRegistry

    init(
        connectionRegistry: RemoteTmuxControlConnectionRegistry,
        transportRegistry: RemoteTmuxTransportRegistry
    ) {
        self.connectionRegistry = connectionRegistry
        self.transportRegistry = transportRegistry
    }

    /// Attaches a `tmux -CC` control connection to `sessionName` on `host`,
    /// reusing an existing live connection for the same host+session.
    @discardableResult
    func attach(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) throws -> RemoteTmuxControlConnection {
        let key = host.connectionKey(sessionName: sessionName)
        if let existing = connectionRegistry.connection(forKey: key) {
            if !existing.exited { return existing }
            // Replace a dead connection — fully tear down the old one first so
            // its ssh process, stdin fd, stream continuation and ingest task
            // don't leak.
            existing.stop()
            connectionRegistry.removeConnection(forKey: key)
        }
        let connection = RemoteTmuxControlConnection(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
        // Insert only after a successful launch, so a failed `start()` never
        // leaves a dead (never-started, `exited == false`) connection that a
        // later attach would wrongly reuse.
        try connection.start()
        connectionRegistry.setConnection(connection, forKey: key)
        return connection
    }

    /// Attaches a single control connection and returns success only after tmux has
    /// emitted `%enter`. Before launching the long-lived control stream, run a
    /// BatchMode tmux probe through the shared transport so auth/session failures
    /// are reported synchronously instead of looking like a successful attach.
    func attachControlStreamWhenReady(
        host: RemoteTmuxHost,
        sessionName: String,
        createIfMissing: Bool = false
    ) async throws -> [String]? {
        if let sshArgv = try await transportRegistry.transport(for: host).preflightControlAttach(
            sessionName: sessionName,
            createIfMissing: createIfMissing
        ) {
            return sshArgv
        }

        let connection = try attach(
            host: host,
            sessionName: sessionName,
            createIfMissing: createIfMissing
        )
        guard await connection.waitUntilConnected() else {
            stopCachedConnectionIfCurrent(connection, host: host, sessionName: sessionName)
            try Task.checkCancellation()
            throw RemoteTmuxError.unreachable("tmux control stream ended before attach for \(host.destination)")
        }
        return nil
    }

    private func stopCachedConnectionIfCurrent(
        _ connection: RemoteTmuxControlConnection,
        host: RemoteTmuxHost,
        sessionName: String
    ) {
        let key = host.connectionKey(sessionName: sessionName)
        guard connectionRegistry.connection(forKey: key) === connection else { return }
        connectionRegistry.removeConnection(forKey: key)
        connection.stop()
    }

    /// Returns the control connection for a host+session, if attached.
    func connection(host: RemoteTmuxHost, sessionName: String) -> RemoteTmuxControlConnection? {
        connectionRegistry.connection(forKey: host.connectionKey(sessionName: sessionName))
    }
}
