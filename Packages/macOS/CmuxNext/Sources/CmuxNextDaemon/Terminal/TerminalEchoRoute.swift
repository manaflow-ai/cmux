public import Foundation

/// Where an attach link's live output goes without the event stream: the view's output lane
/// (``TerminalAttachment/setOutputSink(_:)``). Called on the link's reader thread, in stream order.
public final class TerminalEchoSink: Sendable {
    /// Queues one output chunk, and the echo of key press `flow` it carries, for parsing. Returns true
    /// when the lane is now above its capacity: the reader then waits until the lane calls `wake`, which
    /// it does exactly once, when it drains or closes. Returns false otherwise and never calls `wake`.
    /// Must not block.
    public typealias Enqueue = @Sendable (_ data: Data, _ flow: UInt64?, _ wake: @escaping @Sendable () -> Void) -> Bool

    private let enqueue: Enqueue

    public init(_ enqueue: @escaping Enqueue) {
        self.enqueue = enqueue
    }

    func enqueueEcho(_ data: Data, flow: UInt64?, wake: @escaping @Sendable () -> Void) -> Bool {
        enqueue(data, flow, wake)
    }
}

/// The marker an attach stream carries behind its records while live output waits to go straight
/// to the view's lane (``TerminalEchoRoute``). The consumer calls ``resume()`` once it applied every
/// event before the marker, in order; then output may skip the stream again.
public final class TerminalOutputMarker: Sendable, Hashable {
    let sequence: UInt64
    private let onResume: @Sendable (UInt64) -> Void

    init(sequence: UInt64, onResume: @escaping @Sendable (UInt64) -> Void) {
        self.sequence = sequence
        self.onResume = onResume
    }

    /// Every event before this marker is applied (output queued on the lane, control applied).
    public func resume() { onResume(sequence) }

    public static func == (lhs: TerminalOutputMarker, rhs: TerminalOutputMarker) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Whether an attach link's next output chunk may go straight to the view's lane, and the one
/// sequence number that keeps it behind every record still on the event stream.
///
/// Output goes to the sink only while the consumer applied every record the stream carried
/// (a control record: grid, replay, snapshot; or output that went the stream's way while the route
/// was shut). Each such record shuts the route; a marker behind it, acknowledged by the consumer
/// once it applied the marker's predecessors, opens it again. At most one marker is in flight: a
/// record queued while one is out asks for the next marker when it is acknowledged, so the last
/// marker is always behind the last record. This is how Mojo's MultiplexRouter keeps one pipe's
/// order across endpoints on different threads: a message waits while an earlier one is not yet
/// dispatched (mojo/public/cpp/bindings/lib/multiplex_router.cc, ProcessIncomingMessage).
struct TerminalEchoRoute: Sendable {
    private(set) var sink: TerminalEchoSink?
    private var markerSent: UInt64 = 0
    private var markerAcknowledged: UInt64 = 0
    /// A record went the stream's way after the marker in flight.
    private var recordAfterMarker = false
    private var closed = false

    /// Output may go to ``sink`` now: nothing on the stream is unapplied.
    var isOpen: Bool {
        sink != nil && !closed && markerAcknowledged == markerSent && !recordAfterMarker
    }

    /// A record was queued on the stream. Returns the sequence of a marker to queue right behind it,
    /// if one is due.
    mutating func recordQueued() -> UInt64? {
        guard sink != nil, !closed else { return nil }
        return requestMarker()
    }

    /// The view's lane changed (nil: none). A new sink waits for a marker behind everything queued
    /// so far; returns its sequence, if one is due now.
    mutating func install(_ sink: TerminalEchoSink?) -> UInt64? {
        self.sink = sink
        guard sink != nil, !closed else { return nil }
        return requestMarker()
    }

    /// The consumer applied everything before marker `sequence`. Returns the sequence of the next
    /// marker to queue when records came after it.
    mutating func acknowledge(_ sequence: UInt64) -> UInt64? {
        guard sequence == markerSent, markerAcknowledged != markerSent else { return nil }
        markerAcknowledged = sequence
        guard recordAfterMarker else { return nil }
        recordAfterMarker = false
        guard sink != nil, !closed else { return nil }
        return requestMarker()
    }

    /// The link detached or its stream ended: output goes the stream's way from now on.
    mutating func close() {
        closed = true
        sink = nil
    }

    private mutating func requestMarker() -> UInt64? {
        guard markerAcknowledged == markerSent else {
            recordAfterMarker = true
            return nil
        }
        markerSent += 1
        recordAfterMarker = false
        return markerSent
    }
}
