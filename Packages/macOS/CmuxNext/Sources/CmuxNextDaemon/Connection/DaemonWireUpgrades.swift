public import CmuxNextIPC

/// The framed IPC upgrades a connection asks for in its handshake (plans/cmux-next/chrome-parity/p05-ipc.md,
/// sections 3.1 and 3.2; cmux-tui/spec/transports.md, "Framed IPC grants").
///
/// Off by default: a connection keeps JSON lines until its owner opts in. Every upgrade is also
/// capability-gated, so a daemon that does not advertise one keeps the connection on lines.
public struct DaemonWireUpgrades: Sendable {
    /// Sends typed v12 commands as REQUEST frames once `ipc-frames-v2` is granted, with the method ids and
    /// priorities of this build's schema (the composition root's `MethodTable.schema` and
    /// `WireSchemaIdentity.built`); nil asks for no frames.
    public var frames: DaemonFrameSchema?
    /// Asks for `attach-streams-v1` (client-minted streams on this connection).
    public var streams: Bool

    public init(frames: DaemonFrameSchema? = nil, streams: Bool = false) {
        self.frames = frames
        self.streams = streams
    }

    /// JSON lines only: what every connection did before framed IPC.
    public static let none = DaemonWireUpgrades()

    var asksAny: Bool { frames != nil || streams }
}

/// The schema a connection frames requests with: its method table and the identity of the schema the table
/// was generated from. Frames name a method by its id and priority alone, so they go only to a daemon whose
/// tables came from the same schema bytes (``WireNegotiation``).
public struct DaemonFrameSchema: Sendable {
    public let table: MethodTable
    public let identity: WireSchemaIdentity

    public init(table: MethodTable, identity: WireSchemaIdentity) {
        self.table = table
        self.identity = identity
    }
}

/// What one connection's handshake was granted. Read from the transport (``LineTransport/wireGrants``).
public struct DaemonWireGrants: Sendable, Equatable {
    /// REQUEST frames go out and REPLY/ERROR frames come back (`ipc-frames-v2`).
    public var frames: Bool
    /// Client-minted streams may open on the connection (`attach-streams-v1`).
    public var streams: Bool

    public init(frames: Bool, streams: Bool) {
        self.frames = frames
        self.streams = streams
    }

    /// No upgrade: JSON lines, no streams.
    public static let linesOnly = DaemonWireGrants(frames: false, streams: false)
}
