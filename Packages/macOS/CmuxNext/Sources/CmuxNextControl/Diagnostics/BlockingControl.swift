#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextCompat
internal import CmuxNextSettings

/// `debug.blocking`: the call sites that blocked the main thread since launch (the main-thread
/// blocking detector, plans/cmux-next/threading-model.md), for the every-action sweep and the
/// benches (Debug and bench builds). `{"reset": true}` zeroes the counts after the report; no other
/// parameter is read (trap mode is set only by `CMUX_BLOCKING_TRAP=1` at launch). It reads the detector's own tables, so it
/// runs off the main thread (socket threading policy) and answers while the main thread is busy.
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
        let report: JSONValue = .object([
            "mode": .string(detector.mode.rawValue),
            "overflow": .number(Double(detector.overflow)),
            "sites": .array(detector.sites.map { site in
                .object([
                    "kind": .string(site.kind.rawValue),
                    "location": .string(site.location),
                    "count": .number(Double(site.count)),
                ])
            }),
        ])
        if params["reset"]?.boolValue == true { detector.resetCounts() }
        return report
    }
}
#endif
