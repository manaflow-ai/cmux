public import Foundation

/// Where an attach link's live output goes without the event stream: the view's output lane
/// (``TerminalAttachment/setOutputSink(_:)``). Called on the link's decode lane (or its reader inline), in
/// stream order.
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
/// marker is always behind the last record.
///
/// Output that comes while a marker is in flight and no record came after it is held here, not
/// queued: it is behind the marker and ahead of nothing, so the acknowledgement hands it to the sink
/// and opens the route. The route therefore opens one round trip after the last record, however
/// fast output keeps coming. A record that comes while output is held takes that output onto the
/// stream ahead of itself.
///
/// On a stream of the shared connection the reader must never wait for one view (``TerminalEventQueue/parksReader``
/// is false), so a full lane and a full hold do not hold it: a chunk the lane took above its capacity shuts the route
/// until the lane wakes it (``laneFilling()``, ``laneDrained(_:)``), and the output meanwhile goes onto the stream,
/// whose bounded queue drops and resyncs; held output past the hold limit goes onto the stream behind its marker
/// (``spillHeld()``). This is how Mojo's MultiplexRouter keeps one pipe's order across
/// endpoints on different threads: a message waits in the router while an earlier one is not yet
/// dispatched (mojo/public/cpp/bindings/lib/multiplex_router.cc, ProcessIncomingMessage).
struct TerminalEchoRoute: Sendable {
    /// One live chunk held behind the marker in flight, its colors, and the press whose echo it carries.
    struct Held: Sendable {
        var data: Data
        var colors: TerminalColors?
        var flow: UInt64?
    }

    /// Where one live output chunk goes.
    enum OutputRoute {
        /// Straight to the sink: nothing on the stream is unapplied.
        case lane(TerminalEchoSink)
        /// Held behind the marker in flight; `full` once the held bytes are above the hold limit.
        case held(full: Bool)
        /// Onto the stream, as a record.
        case stream
    }

    /// What an acknowledged marker lets happen.
    enum Acknowledged {
        /// A stale or repeated marker, or nothing to do.
        case nothing
        /// Records came after the marker: queue the next one.
        case marker(UInt64)
        /// The route is open: hand `held`, in order, to `sink` first.
        case open(TerminalEchoSink, held: [Held])
    }

    private(set) var sink: TerminalEchoSink?
    /// Held bytes above which the reader waits for the acknowledgement (the lane's capacity).
    let holdLimit: Int
    private var markerSent: UInt64 = 0
    private var markerAcknowledged: UInt64 = 0
    /// A record went the stream's way after the marker in flight.
    private var recordAfterMarker = false
    private var closed = false
    private var held: [Held] = []
    private var heldBytes = 0
    /// Chunks the lane took whose wake has not come (shared stream only): while any is out, the route stays shut.
    private var laneFills = 0
    /// Counts the sinks installed: a wake of an older sink changes nothing.
    private var sinkGeneration: UInt64 = 0

    init(holdLimit: Int) {
        self.holdLimit = holdLimit
    }

    /// Output may go to ``sink`` now: nothing on the stream is unapplied.
    var isOpen: Bool {
        sink != nil && !closed && !markerInFlight && !recordAfterMarker && laneFills == 0
    }

    private var markerInFlight: Bool { markerAcknowledged != markerSent }

    /// Routes one live output chunk. A chunk that goes to the stream is a record: the caller then
    /// calls ``recordQueued()``.
    mutating func route(_ data: Data, colors: TerminalColors?, flow: UInt64?) -> OutputRoute {
        if isOpen, let sink { return .lane(sink) }
        guard sink != nil, !closed, markerInFlight, !recordAfterMarker, laneFills == 0 else { return .stream }
        held.append(Held(data: data, colors: colors, flow: flow))
        heldBytes += data.count
        return .held(full: heldBytes > holdLimit)
    }

    /// Shared stream: the caller hands one chunk to the lane now. Until the lane's wake for it comes
    /// (``laneDrained(_:)``, also when the lane did not fill), the route stays shut and output goes onto the stream.
    /// Returns the generation to pass back.
    mutating func laneFilling() -> UInt64 {
        laneFills += 1
        return sinkGeneration
    }

    /// Shared stream: the lane drained below its capacity (or never went above it) for one chunk of
    /// ``laneFilling()``'s `generation`. The route opens once none is out and nothing on the stream is unapplied.
    mutating func laneDrained(_ generation: UInt64) {
        guard generation == sinkGeneration, laneFills > 0 else { return }
        laneFills -= 1
    }

    /// Shared stream: the output held behind the marker in flight is past the hold limit. It goes onto the
    /// stream now, behind that marker and ahead of everything later, which goes the stream's way too until the
    /// marker after it is acknowledged.
    mutating func spillHeld() -> [Held] {
        recordAfterMarker = true
        return takeHeld()
    }

    /// The output held so far, which must go onto the stream before the record the caller queues next.
    mutating func takeHeld() -> [Held] {
        defer {
            held = []
            heldBytes = 0
        }
        return held
    }

    /// A record was queued on the stream. Returns the sequence of a marker to queue right behind it,
    /// if one is due.
    mutating func recordQueued() -> UInt64? {
        guard sink != nil, !closed else { return nil }
        return requestMarker()
    }

    /// The view's lane changed (nil: none). A new sink waits for a marker behind everything queued
    /// so far; returns the output held for the old sink, which goes onto the stream first, and the
    /// sequence of the marker to queue behind it, if one is due now.
    mutating func install(_ sink: TerminalEchoSink?) -> (held: [Held], marker: UInt64?) {
        let held = takeHeld()
        self.sink = sink
        sinkGeneration += 1
        laneFills = 0
        guard sink != nil, !closed else { return (held, nil) }
        return (held, requestMarker())
    }

    /// The consumer applied everything before marker `sequence`.
    mutating func acknowledge(_ sequence: UInt64) -> Acknowledged {
        guard sequence == markerSent, markerInFlight else { return .nothing }
        markerAcknowledged = sequence
        if recordAfterMarker {
            recordAfterMarker = false
            guard sink != nil, !closed, let next = requestMarker() else { return .nothing }
            return .marker(next)
        }
        // Only output came after the marker, and it is held here (install and close take it first). While the
        // lane is full nothing is held (the output goes onto the stream): the lane's wake opens the route.
        guard let sink, !closed, laneFills == 0 else { return .nothing }
        return .open(sink, held: takeHeld())
    }

    /// The link detached or its stream ended: output goes the stream's way from now on. Returns the
    /// output held so far, which goes onto the stream before anything else.
    mutating func close() -> [Held] {
        closed = true
        sink = nil
        sinkGeneration += 1
        laneFills = 0
        return takeHeld()
    }

    private mutating func requestMarker() -> UInt64? {
        guard !markerInFlight else {
            recordAfterMarker = true
            return nil
        }
        markerSent += 1
        recordAfterMarker = false
        return markerSent
    }
}
