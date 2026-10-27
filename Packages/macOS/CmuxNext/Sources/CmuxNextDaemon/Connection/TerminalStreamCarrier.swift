/// The ready control transport terminal views stream on, with its daemon's identity (p05-ipc-095).
struct TerminalStreamCarrier: Sendable {
    let transport: LineTransport
    let identity: DaemonIdentity

    /// `connection`'s carrier: only when it asked for terminal streams
    /// (``DaemonConnectionConfiguration/terminalStreams``) and its daemon offered the grant it echoed. Nil sends
    /// each view to a connection of its own.
    static func of(_ connection: DaemonConnection) async -> TerminalStreamCarrier? {
        guard connection.configuration.streamsTerminals, let ready = await connection.ready,
              ready.identity.supports(TerminalAttachment.streamsCapability), !ready.transport.isClosed else { return nil }
        return TerminalStreamCarrier(transport: ready.transport, identity: ready.identity)
    }
}
