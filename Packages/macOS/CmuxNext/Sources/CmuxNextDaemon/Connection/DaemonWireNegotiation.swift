import CmuxNextIPC

/// The app's half of the framed IPC grant rule (cmux-tui capabilities.rs, `IpcCapability::allowed`).
///
/// The daemon offers in `identify` what the connection may be granted, and grants what the client echoes in
/// `set-client-info`. Frames need a direct local peer at exactly the daemon's API revision, because their
/// payloads skip the daemon's revision translation; streams are JSON lines, so a bridge carries them at any
/// revision. Mojo binds an interface only on a channel that can carry it and assumes both ends of an
/// unversioned interface come from one build (mojo/core/channel_posix.cc;
/// mojo/public/tools/bindings/README.md, "Versioning").
///
/// An equal API revision does not prove equal method tables: a new command is additive and takes no new
/// revision (cmux-api-compat coverage.rs), and the daemon closes the connection on a method id or priority
/// its table does not have (frame_dispatch.rs `CallRefusal`). So frames are used only when the daemon's
/// `identify {revisions}` names the same schema digest as this build's table, and only for the methods it
/// lists as answered on frames (`framed_methods`). The connection never learns either by trial, which
/// would run a refused request after the requests written behind it.
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

    /// `digest` as the daemon writes `sdk_schema_digest`: 16 lowercase hex digits (frame_dispatch.rs).
    static func digestText(_ digest: UInt64) -> String {
        let hex = String(digest, radix: 16)
        return String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    /// What to echo to a daemon whose first `identify` offered `offered`; nil when nothing is offered or asked,
    /// so the handshake stays what it was (an older daemon refuses `revisions` and `api_revision`).
    func echo(offered identity: DaemonIdentity) -> Echo? {
        let frames = bridged || !identity.supports(Self.framesCapability) ? nil : upgrades.frames
        let streams = upgrades.streams && identity.supports(Self.streamsCapability)
        guard frames != nil || streams else { return nil }
        return Echo(frames: frames, streams: streams)
    }

    /// What the handshake got: the grants and, with frames granted, how requests are framed.
    struct Granted: Sendable {
        var grants: DaemonWireGrants
        var framing: FramedRequests?

        static let linesOnly = Granted(grants: .linesOnly, framing: nil)
    }

    /// The framed IPC part of one `set-client-info`, and how to read what it got.
    struct Echo {
        /// The schema to frame with, when the echo asks for frames.
        let frames: DaemonFrameSchema?
        let streams: Bool

        var asksFrames: Bool { frames != nil }

        /// The capability names to echo next to the connection's own.
        var capabilities: [String] {
            (asksFrames ? [WireNegotiation.framesCapability] : []) + (streams ? [WireNegotiation.streamsCapability] : [])
        }

        /// The `api_revision` to declare: the grant of frames needs it; a daemon that offers a framed
        /// capability reads it.
        var apiRevision: UInt32 { WireNegotiation.apiRevision }

        /// What was granted, from whether the echoing `set-client-info` succeeded and the `identify {revisions}`
        /// that followed it. The daemon grants frames only at its own revision, and an `identify` after the
        /// declaration lists frames only while the connection may still hold them. Frames are used only when
        /// that `identify` names this build's schema digest, and then only for the methods it lists.
        func granted(accepted: Bool, after revisions: DaemonIdentity?) -> Granted {
            guard accepted else { return .linesOnly }
            let framing = frames.flatMap { schema in revisions.flatMap { Self.framing(schema, daemon: $0) } }
            return Granted(grants: DaemonWireGrants(frames: framing != nil, streams: streams), framing: framing)
        }

        private static func framing(_ schema: DaemonFrameSchema, daemon: DaemonIdentity) -> FramedRequests? {
            guard daemon.apiRevision == WireNegotiation.apiRevision,
                  daemon.supports(WireNegotiation.framesCapability),
                  daemon.sdkSchemaDigest == WireNegotiation.digestText(schema.identity.sdkSchemaDigest),
                  let served = daemon.framedMethods, !served.isEmpty else { return nil }
            return FramedRequests(table: schema.table, served: Set(served.map { MethodID(rawValue: $0) }))
        }
    }
}
