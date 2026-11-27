#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextSettings

extension BurstTrace {
    /// Runs `debug.burst` (DEBUG and bench builds), for scripts/cmux-next/burst-bench.py.
    ///
    /// - `{"action": "start"}` clears the record and arms a recording; the reply carries `facts` (the app
    ///   passes the key repeat it reads, `key_repeat_delay_s` and `key_repeat_interval_s`, and the close
    ///   guard's `quick_press_window_s`, so a bench plays a held key as this host repeats it).
    /// - `{"action": "status"}` returns `facts` (the app adds whether its key sequence still plays, its
    ///   pending creates, whether a terminal grid still waits to go and the terminals whose sent grid the
    ///   daemon has not echoed yet) with `awaiting_output_surfaces` (``awaitingOutputCount``): what the
    ///   bench waits for before it reads.
    /// - `{"action": "stop"}` disarms and returns the record: `events` (oldest first, each with `kind`,
    ///   `at_s` in seconds of `CLOCK_UPTIME_RAW` (`NSEvent.timestamp`'s clock), `event_s` (the timestamp of
    ///   the person's key event the mark answers, when known), for grids and outputs `surface`, `cols`,
    ///   `rows`, and for a close `tabs` and `empties_pane`), `counts` by kind, and `dropped` (marks past
    ///   ``capacity``).
    ///
    /// - Parameters:
    ///   - params: The request's parameters.
    ///   - facts: The host's input facts the `start` reply carries.
    /// - Returns: The reply, or an `error` for another action.
    public func control(_ params: [String: JSONValue], facts: [String: JSONValue] = [:]) -> JSONValue {
        switch params["action"]?.stringValue {
        case "start":
            start()
            return .object(facts.merging(["recording": .bool(true)]) { _, new in new })
        case "status":
            return .object(facts.merging(["recording": .bool(isArmed),
                                          "awaiting_output_surfaces": JSONValue(awaitingOutputCount)]) { _, new in new })
        case "stop":
            let (events, dropped) = stop()
            var counts: [String: JSONValue] = [:]
            for event in events { counts[event.kind.rawValue] = .number((counts[event.kind.rawValue]?.doubleValue ?? 0) + 1) }
            return .object(["events": .array(events.map(eventJSON)), "counts": .object(counts), "dropped": JSONValue(dropped)])
        default:
            return .object(["error": .string("action must be start, status or stop")])
        }
    }
}

/// One ``BurstTrace/Event`` as `debug.burst` reports it.
private func eventJSON(_ event: BurstTrace.Event) -> JSONValue {
    var fields: [String: JSONValue] = ["kind": .string(event.kind.rawValue), "at_s": .number(Double(event.at) / 1e9)]
    if let input = event.input { fields["event_s"] = .number(input) }
    if let surface = event.surface { fields["surface"] = .string(String(surface)) }
    if let cols = event.cols { fields["cols"] = JSONValue(cols) }
    if let rows = event.rows { fields["rows"] = JSONValue(rows) }
    if let expectsEcho = event.expectsEcho { fields["expects_echo"] = .bool(expectsEcho) }
    if let tabs = event.tabs { fields["tabs"] = .array(tabs.map(JSONValue.string)) }
    if let emptiesPane = event.emptiesPane { fields["empties_pane"] = .bool(emptiesPane) }
    return .object(fields)
}
#endif
