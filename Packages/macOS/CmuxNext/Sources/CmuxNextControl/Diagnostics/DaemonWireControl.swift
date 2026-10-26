#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
internal import CmuxNextSettings

/// `debug.daemon.wire`: the app side of the daemon wire since launch (``DaemonWireStats``): bytes and
/// lines each way, inbound lines by kind, JSON decodes per line, terminal output bytes the app copied,
/// and connections and bridge spawns by role, for the p05-ipc benches (Debug and bench builds).
/// `{"reset": true}` zeroes the traffic counters after the report; connection counts never reset.
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
            .object(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.name, number($0.value)) }))
        }
        return .object([
            "bytes_read": number(snapshot.bytesRead),
            "bytes_written": number(snapshot.bytesWritten),
            "lines_read": number(snapshot.linesRead),
            "lines_written": number(snapshot.linesWritten),
            "frames_read": .object(Dictionary(uniqueKeysWithValues: snapshot.framesRead.map { ($0.key.name, number($0.value)) })),
            "envelope_decodes": number(snapshot.envelopeDecodes),
            "consumer_decodes": number(snapshot.consumerDecodes),
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
        ])
    }
}
#endif
