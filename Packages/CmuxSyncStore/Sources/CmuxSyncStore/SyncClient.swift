public import Foundation

/// A duplex frame transport the `SyncClient` drives. The presence WebSocket
/// implements this (send `sync.hello` text, receive server frames); a fake
/// implements it in tests. Kept minimal and transport-agnostic so the client
/// logic does not depend on URLSession specifics, mirroring how `PresenceClient`
/// already wraps its WS task.
public protocol SyncTransport: Sendable {
    /// Send a text frame (the `sync.hello`).
    func send(_ data: Data) async throws
    /// The inbound frame stream. Each element is one raw WS message (which the
    /// client parses with `SyncFrameCodec`). Ends when the socket closes.
    func frames() -> AsyncThrowingStream<Data, any Error>
}

/// The generic sync/v1 client (DESIGN.md §3.3 / §12). Subscribes a set of
/// collections over a `SyncTransport`, sends `sync.hello` with the cursors the
/// store already holds, then feeds every inbound frame to a `SyncFrameApplier`
/// which lands them in the local SQLite store. The UI reads the store and is
/// invalidated by an optional `onApplied` callback after each committed frame
/// (the apply-callback, never a view-body mutation, per the repo's SwiftUI
/// rules, DESIGN.md §10a).
///
/// This is the shell; the protocol-correct apply state machine lives in
/// `SyncFrameApplier` (unit-tested separately). Connection retry/backoff is the
/// caller's concern (it owns the transport lifecycle), matching how the presence
/// client is reconnected today.
public struct SyncClient: Sendable {
    private let transport: any SyncTransport
    private let applier: SyncFrameApplier
    private let collections: [String]
    private let onApplied: (@Sendable () async -> Void)?

    public init(
        transport: any SyncTransport,
        applier: SyncFrameApplier,
        collections: [String],
        onApplied: (@Sendable () async -> Void)? = nil
    ) {
        self.transport = transport
        self.applier = applier
        self.collections = collections
        self.onApplied = onApplied
    }

    /// Run one subscription session: send hello, then apply frames until the
    /// stream ends or throws. Resets any in-flight snapshot build on exit so a
    /// reconnect starts clean. Throws on transport failure so the caller can
    /// back off and reconnect.
    public func run() async throws {
        // Send hello with the persisted cursor per collection (DESIGN.md §3.3 t0+).
        var subs: [(name: String, cursor: Int)] = []
        for name in collections {
            subs.append((name: name, cursor: try await applier.cursor(collection: name)))
        }
        try await transport.send(try SyncFrameCodec.encodeHello(collections: subs))

        do {
            for try await raw in transport.frames() {
                // A frame that claims to be sync but is broken throws; a presence
                // frame parses as `.unknown` and is ignored by the applier.
                let frame: SyncServerFrame
                do {
                    frame = try SyncFrameCodec.parse(raw)
                } catch {
                    continue // skip an unparseable frame rather than tearing down
                }
                try await applier.apply(frame)
                if let onApplied { await onApplied() }
            }
        } catch {
            await applier.resetInFlight()
            throw error
        }
        await applier.resetInFlight()
    }
}
