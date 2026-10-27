#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
internal import CmuxNextSettings

/// `debug.daemon.wire`: the app side of the daemon wire since launch (``DaemonWireStats``): bytes and
/// lines each way, inbound lines by kind, JSON decodes per line, terminal output bytes the app copied,
/// connections and bridge spawns by role, and each method's send-to-reply time (`methods`, the app
/// end of the daemon's `server-stats` `ipc_methods`), for the p05-ipc benches (Debug and bench builds).
/// `{"reset": true}` zeroes the traffic counters and the method histograms after the report;
/// connection counts never reset.
/// It reads atomics only, so it runs off the main thread (socket threading policy) and answers while
/// the main thread is busy.
public struct DaemonWireControl: Sendable {
    /// The control socket's JSON (CmuxNextDaemon has its own of the same name).
    typealias JSONValue = CmuxNextSettings.JSONValue

    private let stats: DaemonWireStats

    /// Makes the method over the recorder the app's transports count into.
    public init(stats: DaemonWireStats) {
        self.stats = stats
    }

    /// The `debug.daemon.wire` control method.
    public var method: ControlMethod {
        .snapshot("debug.daemon.wire") { [stats] call in Self.report(call.params, stats: stats) }
    }

    static func report(_ params: [String: JSONValue], stats: DaemonWireStats) -> JSONValue {
        let snapshot = stats.snapshot()
        if params["reset"]?.boolValue == true { stats.resetTraffic() }
        return report(snapshot)
    }

    static func report(_ snapshot: DaemonWireStats.Snapshot) -> JSONValue {
        func number(_ value: UInt64) -> JSONValue { .number(Double(value)) }
        func byRole(_ counts: [DaemonWireStats.Role: UInt64]) -> JSONValue {
            .object(Dictionary(counts.map { ($0.key.name, number($0.value)) }, uniquingKeysWith: { first, _ in first }))
        }
        return .object([
            "bytes_read": number(snapshot.bytesRead),
            "bytes_written": number(snapshot.bytesWritten),
            "lines_read": number(snapshot.linesRead),
            "lines_written": number(snapshot.linesWritten),
            "frames_read": .object(Dictionary(snapshot.framesRead.map { ($0.key.name, number($0.value)) }, uniquingKeysWith: { first, _ in first })),
            "json_decodes": number(snapshot.jsonDecodes),
            "decodes_per_line": .number(snapshot.decodesPerLine),
            "output_bytes_copied_app": number(snapshot.outputBytesCopiedApp),
            "connections": .object([
                "opened": byRole(snapshot.connectionsOpened),
                "closed": byRole(snapshot.connectionsClosed),
                "open": byRole(snapshot.connectionsOpen),
                "opened_total": number(snapshot.connectionsOpenedTotal),
            ]),
            "bridge_spawns": byRole(snapshot.bridgeSpawns),
            "bridge_spawns_total": number(snapshot.bridgeSpawnsTotal),
            "methods": .array(snapshot.methods.map(methodRow)),
        ])
    }

    /// One method's row: `method`; `id`, the schema `method_id` (null for `other`), which the
    /// daemon's `server-stats` `ipc_methods` rows carry too, so the two reports join on `id`;
    /// `send_to_reply_us` with `count`, `p50`, `p95`, `p99` and `max` (the daemon's percentile keys;
    /// a timed-out request counts at its deadline); `timed_out`; and `abandoned`, the requests whose
    /// connection closed before their reply.
    static func methodRow(_ latency: DaemonWireStats.MethodLatency) -> JSONValue {
        func number(_ value: UInt64) -> JSONValue { .number(Double(value)) }
        return .object([
            "method": .string(latency.method),
            "id": latency.id.map { JSONValue.number(Double($0)) } ?? .null,
            "timed_out": number(latency.timedOut),
            "abandoned": number(latency.abandoned),
            "send_to_reply_us": .object([
                "count": number(latency.count),
                "p50": number(latency.p50Micros),
                "p95": number(latency.p95Micros),
                "p99": number(latency.p99Micros),
                "max": number(latency.maxMicros),
            ]),
        ])
    }
}
#endif
