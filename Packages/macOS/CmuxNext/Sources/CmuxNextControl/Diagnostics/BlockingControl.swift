#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
internal import CmuxNextSettings

/// `debug.blocking`: the call sites that blocked the main thread, a shared pool thread or a `.cpu` lane item, or
/// waited on a sync primitive in a lane item, since launch (the blocking detector, plans/cmux-next/threading-model.md),
/// for the every-action sweep and the benches (Debug and bench-checks builds). Each site has its context (`main`,
/// `pool`, `cpu-lane` with kind `wrong-lane`, whose `seam_kind` says what the seam waited on, or `lane-sync`), its
/// call count and, for calls timed by
/// `blockingCall`, the wall time they blocked (`total_ms`, `max_ms`); `contexts` sums the sites per context,
/// with each context's `overflow` (calls not recorded as a site; the top-level `overflow` is their sum).
/// `{"reset": true}` zeroes the counts and times after the report; no other parameter is read (trap modes are set
/// only by `CMUX_BLOCKING_TRAP=1` and `CMUX_BLOCKING_TRAP_POOL=1` at launch). It reads the detector's own tables,
/// so it runs off the main thread (socket threading policy) and answers while the main thread is busy.
///
/// The method also answers in a `--config bench` build, which has no detector: there `compiled_in` is false
/// and `sites` is always empty, so a reader must refuse such a report rather than read it as no blocking.
public struct BlockingControl: Sendable {
    private let detector: BlockingDetector

    /// Makes the method over the composition root's detector handle.
    public init(detector: BlockingDetector) {
        self.detector = detector
    }

    /// The `debug.blocking` control method.
    public var method: ControlMethod {
        .snapshot("debug.blocking") { [detector] call in Self.report(call.params, detector: detector) }
    }

    static func report(_ params: [String: JSONValue], detector: BlockingDetector) -> JSONValue {
        let sites = detector.sites
        var contexts: [String: JSONValue] = [:]
        for context in [BlockingContext.main, .pool, .cpuLane, .laneSync] {
            let inContext = sites.filter { $0.context == context }
            contexts[context.rawValue] = .object([
                "sites": .number(Double(inContext.count)),
                "count": .number(Double(inContext.reduce(0) { $0 + $1.count })),
                "overflow": .number(Double(detector.overflow(in: context))),
            ])
        }
        let report: JSONValue = .object([
            "compiled_in": .bool(detector.isCompiledIn),
            "mode": .string(detector.mode.rawValue),
            "pool_mode": .string(detector.poolMode.rawValue),
            "overflow": .number(Double(detector.overflow)),
            "contexts": .object(contexts),
            "sites": .array(sites.map { site in
                .object([
                    "context": .string(site.context.rawValue),
                    "kind": .string(site.kind.rawValue),
                    "seam_kind": .string(site.seamKind.rawValue),
                    "location": .string(site.location),
                    "count": .number(Double(site.count)),
                    "total_ms": .number(Double(site.totalNanos) / 1_000_000),
                    "max_ms": .number(Double(site.maxNanos) / 1_000_000),
                ])
            }),
        ])
        if params["reset"]?.boolValue == true { detector.resetCounts() }
        return report
    }
}
#endif
