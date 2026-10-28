import Foundation

/// One item the reader thread routes to an attach stream's sink (attach-streams-v1, cmux-tui/spec/events.md
/// "Attach streams").
enum AttachStreamDelivery: Sendable {
    /// An item of the stream: its event name and its whole line.
    case event(name: String, line: Data)
    /// The stream's `stream-end` line, its last item; the id is free once it is routed.
    case end(line: Data)
    /// The connection ended, which ends every stream on it with no `stream-end`.
    case lost(TransportCloseReason)
}

/// Where one attach stream's items go. The reader only routes them: each item runs on the connection's
/// ``DecodeLane`` in wire order, weighed as the stream's `dispatch` says, and the reader runs the stream's
/// ``EventDispatch/readerWait`` after the item, outside its hang scope, so a lane item never waits on the view.
struct AttachStreamSink: Sendable {
    /// The weight of each item and the reader's wait after it.
    let dispatch: EventDispatch
    /// The connection's decode lane, in wire order: one item of the stream. Never waits.
    let deliver: @Sendable (AttachStreamDelivery) -> Void

    init(dispatch: EventDispatch, deliver: @escaping @Sendable (AttachStreamDelivery) -> Void) {
        self.dispatch = dispatch
        self.deliver = deliver
    }
}

/// A stream id this side minted, with the epoch of that minting, so a late cancel or release of an
/// id that ended and was minted again never touches the newer stream.
struct AttachStreamHandle: Sendable, Hashable {
    let id: UInt16
    let epoch: UInt64
}

/// The client-minted attach streams of one connection, kept in the transport's state
/// under its one lock. Chrome's `MultiplexRouter` works the same way: the side that associates an
/// endpoint picks its id, every message names it, and the id is forgotten only once the peer's
/// closed notification arrived (mojo/public/cpp/bindings/lib/multiplex_router.cc,
/// `AssociateInterface`, `UpdateEndpointStateMayRemove`). Here that notification is `stream-end`.
///
/// Ids run 1...65535 in turn (0 is the control sequence) and skip ids still taken, so an id is
/// used again only after every other free id was.
struct AttachStreamTable {
    /// The event that ends a stream.
    static let endEvent = "stream-end"

    private enum Entry {
        /// Minted; its sink is bound before the open request goes out.
        case reserved(epoch: UInt64)
        case open(epoch: UInt64, AttachStreamSink)
        /// Its owner let go; items are dropped until `stream-end` frees the id.
        case cancelled(epoch: UInt64)

        var epoch: UInt64 {
            switch self {
            case .reserved(let epoch), .open(let epoch, _), .cancelled(let epoch): epoch
            }
        }
    }

    /// What ``route(_:ended:)`` found for a stream id.
    enum Route {
        /// Hand the item to this sink.
        case deliver(AttachStreamSink)
        /// Nobody reads it: the id is reserved or cancelled, or no longer held.
        case dropped
        /// This side never minted a stream: the line is not an attach item (a `loopback-*` event of a
        /// connection of its own also names a `stream`).
        case unknown
    }

    private var entries: [UInt16: Entry] = [:]
    private var lastMinted: UInt16 = 0
    private var epochs: UInt64 = 0
    /// Set when the connection ended; no id is minted after it.
    private(set) var closed = false

    /// Ids taken: open, reserved, or cancelled and waiting for their `stream-end`.
    var count: Int { entries.count }

    /// Takes the next free id. Nil once the connection ended or when every id is taken.
    mutating func reserve() -> AttachStreamHandle? {
        guard !closed, let id = nextFreeID() else { return nil }
        lastMinted = id
        epochs += 1
        entries[id] = .reserved(epoch: epochs)
        return AttachStreamHandle(id: id, epoch: epochs)
    }

    /// The first free id after the last one minted, wrapping past 65535 to 1; nil when every id is taken.
    private func nextFreeID() -> UInt16? {
        let after = lastMinted == .max ? 1 : lastMinted + 1
        return (after...UInt16.max).first { entries[$0] == nil } ?? (1..<after).first { entries[$0] == nil }
    }

    /// Binds `sink` to a reserved id; false when the id is no longer this handle's.
    mutating func bind(_ handle: AttachStreamHandle, _ sink: AttachStreamSink) -> Bool {
        guard case .reserved(let epoch)? = entries[handle.id], epoch == handle.epoch else { return false }
        entries[handle.id] = .open(epoch: epoch, sink)
        return true
    }

    /// Stops delivery to the handle's stream; the id stays taken until its `stream-end` or the reply of the
    /// `cancel-stream` this asks for. True when the stream was not cancelled yet (that `cancel-stream` is due),
    /// false when it ended or was cancelled already.
    mutating func cancel(_ handle: AttachStreamHandle) -> Bool {
        guard let entry = entries[handle.id], entry.epoch == handle.epoch else { return false }
        if case .cancelled = entry { return false }
        entries[handle.id] = .cancelled(epoch: handle.epoch)
        return true
    }

    /// Frees the handle's id when the daemon will send nothing more for it (an open that failed, or the reply
    /// of its `cancel-stream`). An id minted again since is left alone.
    mutating func release(_ handle: AttachStreamHandle) {
        guard entries[handle.id]?.epoch == handle.epoch else { return }
        entries[handle.id] = nil
    }

    /// Where an item of stream `id` goes; `ended` (its `stream-end`) frees the id.
    mutating func route(_ id: UInt16, ended: Bool) -> Route {
        guard let entry = entries[id] else { return epochs == 0 ? .unknown : .dropped }
        if ended { entries[id] = nil }
        guard case .open(_, let sink) = entry else { return .dropped }
        return .deliver(sink)
    }

    /// The connection ended: every id is free, nothing is minted again, and the open streams' sinks
    /// are returned to be told.
    mutating func endAll() -> [AttachStreamSink] {
        closed = true
        let sinks = entries.values.compactMap { entry -> AttachStreamSink? in
            guard case .open(_, let sink) = entry else { return nil }
            return sink
        }
        entries.removeAll()
        return sinks
    }
}
