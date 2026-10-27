public import CmuxNextIPC

/// The framed IPC upgrades a connection asks for in its handshake (plans/cmux-next/chrome-parity/p05-ipc.md,
/// sections 3.1 and 3.2; cmux-tui/spec/transports.md, "Framed IPC grants").
///
/// Off by default: a connection keeps JSON lines until its owner opts in. Every upgrade is also
/// capability-gated, so a daemon that does not advertise one keeps the connection on lines.
public struct DaemonWireUpgrades: Sendable {
    /// Sends typed v12 commands as REQUEST frames once `ipc-frames-v2` is granted, with the method ids and
    /// priorities of this table (the composition root's `MethodTable.schema`); nil asks for no frames.
    public var methodTable: MethodTable?
    /// Asks for `attach-streams-v1` (client-minted streams on this connection).
    public var streams: Bool

    public init(methodTable: MethodTable? = nil, streams: Bool = false) {
        self.methodTable = methodTable
        self.streams = streams
    }

    /// JSON lines only: what every connection did before framed IPC.
    public static let none = DaemonWireUpgrades()

    var asksAny: Bool { methodTable != nil || streams }
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

/// The app's half of the framed IPC grant rule (cmux-tui capabilities.rs, `IpcCapability::allowed`).
///
/// The daemon offers in `identify` what the connection may be granted, and grants what the client echoes in
/// `set-client-info`. Frames need a direct local peer at exactly the daemon's API revision, because their
/// payloads skip the daemon's revision translation; streams are JSON lines, so a bridge carries them at any
/// revision. Mojo binds an interface only on a channel that can carry it and assumes both ends of an
/// unversioned interface come from one build (mojo/core/channel_posix.cc;
/// mojo/public/tools/bindings/README.md, "Versioning").
struct WireNegotiation {
    /// The daemon's grant names (cmux-tui capabilities.rs, `IpcCapability::name`).
    static let framesCapability = "ipc-frames-v2"
    static let streamsCapability = "attach-streams-v1"

    /// The API revision this build's wire types speak: the last revision of cmux-tui/spec/api-compat.json, or
    /// its `base` while it lists none (cmux-api-compat `Schema::current`). DaemonHandshakeTests reads the file
    /// and fails when the two differ.
    static let apiRevision: UInt32 = 12

    let upgrades: DaemonWireUpgrades
    /// The connection runs through a byte bridge (`cmux link dial`, a relay): the daemon may see the bridge as
    /// a direct peer, so only the client knows frames cannot pass and never asks for them.
    let bridged: Bool

    /// What to echo to a daemon whose first `identify` offered `offered`; nil when nothing is offered or asked,
    /// so the handshake stays what it was (an older daemon refuses `revisions` and `api_revision`).
    func echo(offered identity: DaemonIdentity) -> Echo? {
        let frames = upgrades.methodTable != nil && !bridged && identity.supports(Self.framesCapability)
        let streams = upgrades.streams && identity.supports(Self.streamsCapability)
        guard frames || streams else { return nil }
        return Echo(frames: frames, streams: streams)
    }

    /// The framed IPC part of one `set-client-info`, and how to read what it got.
    struct Echo {
        let frames: Bool
        let streams: Bool

        /// The capability names to echo next to the connection's own.
        var capabilities: [String] {
            (frames ? [WireNegotiation.framesCapability] : []) + (streams ? [WireNegotiation.streamsCapability] : [])
        }

        /// The `api_revision` to declare: the grant of frames needs it; a daemon that offers a framed
        /// capability reads it.
        var apiRevision: UInt32 { WireNegotiation.apiRevision }

        /// The grants, from whether the echoing `set-client-info` succeeded and the `identify {revisions}` that
        /// followed it. The daemon grants frames only at its own revision, and an `identify` after the
        /// declaration lists frames only while the connection may still hold them.
        func grants(accepted: Bool, after revisions: DaemonIdentity?) -> DaemonWireGrants {
            guard accepted else { return .linesOnly }
            let frames = frames && revisions.map {
                $0.apiRevision == WireNegotiation.apiRevision && $0.supports(WireNegotiation.framesCapability)
            } == true
            return DaemonWireGrants(frames: frames, streams: streams)
        }
    }
}
