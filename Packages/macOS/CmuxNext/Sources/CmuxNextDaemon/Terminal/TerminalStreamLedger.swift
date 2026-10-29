public import Foundation

/// Byte counts of one attach link's live output at each stage the link owns, for `debug.surfaces`: what the
/// daemon said it sent (its `offset`), what the link decoded, what the snapshot order dropped, and where the
/// echo router put the rest (straight to the view's lane, held behind a marker, or onto the event stream).
/// The view's lane counts what it queued and parsed itself (``TerminalOutputLane``), so a view that stops
/// showing output while its daemon goes on names the stage its bytes stopped at.
///
/// Counted under the echo router's own lock, where each line is already routed: no lock, wait or allocation
/// of its own. Only counts: nothing reads them to decide anything.
public nonisolated struct TerminalStreamLedger: Sendable, Equatable {
    /// The daemon's PTY offset after the last `output` line (its `offset`); nil before one carried it.
    public var daemonOffset: UInt64?
    /// Output bytes decoded for this link's surface.
    public var decodedBytes = 0
    /// Output bytes the snapshot order dropped (a generation older than the last READY).
    public var droppedBytes = 0
    /// Output bytes handed straight to the view's lane.
    public var laneBytes = 0
    /// Output bytes held behind a marker in flight, in all.
    public var heldBytes = 0
    /// Held bytes a marker's acknowledgement handed to the lane.
    public var heldToLaneBytes = 0
    /// Held bytes moved onto the event stream (a record came, the lane changed or the link closed).
    public var heldToStreamBytes = 0
    /// Output bytes queued on the event stream as records (the route was shut and nothing was in flight).
    public var streamBytes = 0
    /// Markers queued behind records, and those the consumer acknowledged.
    public var markersSent = 0
    public var markersAcknowledged = 0
    /// READY snapshots admitted, and how many of them were local-history READYs.
    public var readies = 0
    public var localReadies = 0
    /// The last READY's cut and generation, whether it was a local-history one, and ``decodedBytes`` then.
    public var readyOffset: UInt64?
    public var readyGeneration: UInt64?
    public var readyWasLocal = false
    public var decodedBytesAtReady = 0
    /// The router's state when read: a lane is installed, and the route to it is open.
    public var hasSink = false
    public var routeOpen = false
    /// The event queue's state when read: output bytes waiting for the view, overflows, events dropped by
    /// them or by a resync, and the resync phase (`idle`, `deferred`, `awaiting_ready`).
    public var queuedBytes = 0
    public var queueOverflows = 0
    public var queueDroppedEvents = 0
    public var queueResync = "idle"
    /// The view's stream on a shared connection (nil: a connection of its own).
    public var stream: UInt16?

    public init() {}

    /// Counts one decoded line before the snapshot order admits it.
    mutating func decoded(_ line: DecodedAttachLine) {
        guard case .output(let data, _) = line.event else { return }
        decodedBytes &+= data.count
        if let offset = line.offset { daemonOffset = offset }
    }

    /// Counts what the snapshot order admitted, or dropped, of `line`.
    mutating func admitted(_ line: DecodedAttachLine, event: TerminalChannelEvent?) {
        switch (line.event, event) {
        case (.output(let data, _), nil): droppedBytes &+= data.count
        case (_, .snapshot(let frame)?) where frame.phase == .ready:
            readies &+= 1
            if frame.localHistory != nil { localReadies &+= 1 }
            readyOffset = frame.offset
            readyGeneration = frame.generation
            readyWasLocal = frame.localHistory != nil
            decodedBytesAtReady = decodedBytes
        default: break
        }
    }
}
