#if DEBUG
public import CmuxNextSettings

extension BurstTrace {
    /// Runs `debug.burst` (DEBUG and bench builds), for scripts/cmux-next/burst-bench.py.
    ///
    /// - `{"action": "start"}` clears the record and arms a recording; the reply carries `facts` (the app
    ///   passes the key repeat it reads, `key_repeat_delay_s` and `key_repeat_interval_s`, and the close
    ///   guard's `quick_press_window_s`, so a bench plays a held key as this host repeats it).
    /// - `{"action": "stop"}` disarms and returns the record: `events` (oldest first, each with `kind`,
    ///   `at_s` in seconds of `CLOCK_UPTIME_RAW` (`NSEvent.timestamp`'s clock), and for grids and outputs
    ///   `surface`, `cols`, `rows`), `counts` by kind, and `dropped` (marks past ``capacity``).
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
        case "stop":
            let (events, dropped) = stop()
            var counts: [String: JSONValue] = [:]
            for event in events { counts[event.kind.rawValue] = .number((counts[event.kind.rawValue]?.doubleValue ?? 0) + 1) }
            return .object(["events": .array(events.map(eventJSON)), "counts": .object(counts), "dropped": JSONValue(dropped)])
        default:
            return .object(["error": .string("action must be start or stop")])
        }
    }
}

/// One ``BurstTrace/Event`` as `debug.burst` reports it.
private func eventJSON(_ event: BurstTrace.Event) -> JSONValue {
    var fields: [String: JSONValue] = ["kind": .string(event.kind.rawValue), "at_s": .number(Double(event.at) / 1e9)]
    if let surface = event.surface { fields["surface"] = .string(String(surface)) }
    if let cols = event.cols { fields["cols"] = JSONValue(cols) }
    if let rows = event.rows { fields["rows"] = JSONValue(rows) }
    return .object(fields)
}
#endif
