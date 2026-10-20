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
    private let allowedCollections: Set<String>
    private let onApplied: (@Sendable () async -> Void)?
    private let codec = SyncFrameCodec()

    /// Construct the client. The subscribed `collections` are also the allowlist:
    /// `run()` rejects any inbound frame for a collection outside this set BY
    /// CONSTRUCTION (independent of how the injected `applier` was configured), so
    /// a misbehaving endpoint cannot grow buffers/cursor state for an unbounded
    /// set of unrequested collection names. The safety invariant is enforced by
    /// the client, not left to each caller to remember.
    public init(
        transport: any SyncTransport,
        applier: SyncFrameApplier,
        collections: [String],
        onApplied: (@Sendable () async -> Void)? = nil
    ) {
        self.transport = transport
        self.applier = applier
        self.collections = collections
        self.allowedCollections = Set(collections)
        self.onApplied = onApplied
    }

    /// The collection a server frame targets, or nil for a presence/unknown frame
    /// (which carries no sync collection and is not subject to the allowlist).
    private func frameCollection(_ frame: SyncServerFrame) -> String? {
        switch frame {
        case let .snapshot(collection, _, _, _, _): return collection
        case let .delta(collection, _, _): return collection
        case let .tick(collection, _): return collection
        case .unknown: return nil
        }
    }

    /// Run one subscription session: send hello, then apply frames until the
    /// stream ends or throws. Resets any in-flight snapshot build on exit so a
    /// reconnect starts clean. Throws on transport failure so the caller can
    /// back off and reconnect.
    public func run() async throws {
        // Send hello with the persisted cursor + epoch per collection so the
        // server can catch up with deltas, or force a reset snapshot on an epoch
        // mismatch (DESIGN.md §3.3 t0+ / §3.6).
        var subs: [(name: String, cursor: Int, epoch: Int)] = []
        for name in collections {
            subs.append((
                name: name,
                cursor: try await applier.cursor(collection: name),
                epoch: try await applier.epoch(collection: name)
            ))
        }
        try await transport.send(try codec.encodeHello(collections: subs))

        do {
            for try await raw in transport.frames() {
                // A presence/non-JSON frame is noise on the shared socket and is
                // skipped; a frame that CLAIMS to be sync but is structurally
                // broken (`.malformed`) must NOT be skipped — skipping it would
                // leave a gap the cursor could later advance past, durably losing
                // a rev. Rethrow so the caller resets the session and re-hellos
                // (a fresh snapshot/catch-up fills the gap).
                let frame: SyncServerFrame
                do {
                    frame = try codec.parse(raw)
                } catch SyncFrameParseError.notJSON {
                    continue // presence frame / non-JSON noise; ignore
                } catch {
                    await applier.resetInFlight()
                    throw error // a malformed sync frame: reset + reconnect to resync
                }
                // Enforce the subscribed-collection allowlist BY CONSTRUCTION: a
                // sync frame for a collection this client never subscribed to is a
                // misbehaving/compromised endpoint trying to grow per-collection
                // buffers + cursor state for an unbounded set of names. Reset and
                // reconnect rather than apply it. (Presence/unknown frames carry no
                // collection and pass through to be ignored by the applier.)
                if let collection = frameCollection(frame), !allowedCollections.contains(collection) {
                    await applier.resetInFlight()
                    throw SyncFrameParseError.malformed("frame for unrequested collection \(collection)")
                }
                // Only fire the UI-invalidation callback when a sync commit
                // actually happened. A presence frame (.unknown), an incomplete
                // snapshot page, or a delta queued during paging commits nothing,
                // so high-frequency presence traffic on this shared socket does
                // not drive spurious SQLite reloads / UI invalidations.
                let committed = try await applier.apply(frame)
                if committed, let onApplied { await onApplied() }
            }
        } catch {
            await applier.resetInFlight()
            throw error
        }
        await applier.resetInFlight()
    }
}
