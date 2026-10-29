public import CmuxNextDaemon
public import CmuxNextSettings

/// One terminal's live output per stage, daemon to surface, as `debug.surfaces` reports it (pane `stream`): the
/// attach link's counts (``TerminalStreamLedger``) and the view's output lane's, so a view that stops showing
/// output while its daemon goes on names the stage its bytes stopped at. Counts only.
public struct TerminalStreamReport: Sendable, Equatable {
    public typealias JSONValue = CmuxNextSettings.JSONValue

    /// The live link's counts; nil without a live link.
    public var ledger: TerminalStreamLedger?
    /// Output bytes the live surface's lane queued, parsed and skipped (surface closing); nil without a lane.
    public var lane: (queued: Int, parsed: Int, skipped: Int)?
    /// The lane the link's reader feeds is the live surface's.
    public var readerFeedsViewLane: Bool?

    public init(ledger: TerminalStreamLedger?, lane: (queued: Int, parsed: Int, skipped: Int)?,
                readerFeedsViewLane: Bool?) {
        self.ledger = ledger
        self.lane = lane
        self.readerFeedsViewLane = readerFeedsViewLane
    }

    public static func == (lhs: TerminalStreamReport, rhs: TerminalStreamReport) -> Bool {
        lhs.ledger == rhs.ledger && lhs.lane.map { [$0.queued, $0.parsed, $0.skipped] } == rhs.lane.map { [$0.queued, $0.parsed, $0.skipped] }
            && lhs.readerFeedsViewLane == rhs.readerFeedsViewLane
    }

    /// The report's JSON object; byte counts as numbers, absent stages as null.
    public var json: JSONValue {
        func number(_ value: UInt64?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
        var object: [String: JSONValue] = [:]
        if let ledger {
            object["daemon_offset"] = number(ledger.daemonOffset)
            object["decoded"] = JSONValue(ledger.decodedBytes)
            object["dropped"] = JSONValue(ledger.droppedBytes)
            object["to_lane"] = JSONValue(ledger.laneBytes)
            object["held"] = JSONValue(ledger.heldBytes)
            object["held_to_lane"] = JSONValue(ledger.heldToLaneBytes)
            object["held_to_stream"] = JSONValue(ledger.heldToStreamBytes)
            object["to_stream"] = JSONValue(ledger.streamBytes)
            object["markers_sent"] = JSONValue(ledger.markersSent)
            object["markers_acknowledged"] = JSONValue(ledger.markersAcknowledged)
            object["readies"] = JSONValue(ledger.readies)
            object["local_readies"] = JSONValue(ledger.localReadies)
            object["ready_offset"] = number(ledger.readyOffset)
            object["ready_generation"] = number(ledger.readyGeneration)
            object["ready_local"] = .bool(ledger.readyWasLocal)
            object["decoded_at_ready"] = JSONValue(ledger.decodedBytesAtReady)
            object["has_sink"] = .bool(ledger.hasSink)
            object["route_open"] = .bool(ledger.routeOpen)
            object["queued"] = JSONValue(ledger.queuedBytes)
            object["queue_overflows"] = JSONValue(ledger.queueOverflows)
            object["queue_dropped_events"] = JSONValue(ledger.queueDroppedEvents)
            object["queue_resync"] = .string(ledger.queueResync)
            object["stream_id"] = ledger.stream.map { .number(Double($0)) } ?? .null
        }
        if let lane {
            object["lane_queued"] = JSONValue(lane.queued)
            object["lane_parsed"] = JSONValue(lane.parsed)
            object["lane_skipped"] = JSONValue(lane.skipped)
        }
        object["reader_feeds_view_lane"] = readerFeedsViewLane.map(JSONValue.bool) ?? .null
        return .object(object)
    }
}
